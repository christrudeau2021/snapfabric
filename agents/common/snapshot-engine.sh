#!/bin/bash
# snapfabric snapshot engine
#
# Pulls one host into a hardlinked, dated snapshot on the hub, prunes to a
# retention policy, and records anything it could not read.
#
#   usage: snapshot-engine.sh <config-file> [--dry-run]
#
# Portable across macOS and Linux hubs. Written for bash 3.2 (macOS ships it):
# no associative arrays, no `mapfile`, no empty-array expansion under `set -u`.
#
# Every non-obvious decision here traces to a documented failure. Read
# docs/CONSTRAINTS.md before changing anything -- particularly the failure path,
# which looks over-engineered and is not.

set -uo pipefail

CONF="${1:-}"
[ -n "$CONF" ] && [ -f "$CONF" ] || { echo "usage: $0 <config-file> [--dry-run]" >&2; exit 2; }
DRY=""; [ "${2:-}" = "--dry-run" ] && DRY="--dry-run"

# ---------------------------------------------------------------------------
# Config. Sourced, so it is plain shell:
#   HOST_TAG, SSH_USER, SSH_HOST, SSH_KEY, DEST_ROOT, SENTINEL
#   SOURCES   (newline-separated absolute paths)
#   EXCLUDES  (newline-separated rsync patterns, anchored to the transfer root)
#   BWLIMIT   (KB/s, 0 = unlimited)
#   KEEP_HOURLY KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090
. "$CONF"

: "${HOST_TAG:?config must set HOST_TAG}"
: "${SSH_USER:?config must set SSH_USER}"
: "${SSH_HOST:?config must set SSH_HOST}"
: "${DEST_ROOT:?config must set DEST_ROOT}"
: "${SSH_KEY:=$HOME/.ssh/snapfabric_$HOST_TAG}"
# Not every host listens on 22. Hardcoding it meant rsync died with a bare
# "exited 255" -- an ssh-level error the engine reports as a transfer failure,
# which sends you looking at the wrong layer entirely.
: "${SSH_PORT:=22}"
: "${BWLIMIT:=0}"
: "${KEEP_HOURLY:=24}"; : "${KEEP_DAILY:=30}"; : "${KEEP_WEEKLY:=8}"; : "${KEEP_MONTHLY:=12}"

STAMP="$(date +%Y-%m-%d_%H%M%S)"
LOG_DIR="${LOG_DIR:-$HOME/.local/state/snapfabric}"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/${HOST_TAG}.log"
HOST_DIR="$DEST_ROOT/$HOST_TAG"
NEW="$HOST_DIR/$STAMP"
LATEST="$HOST_DIR/latest"

log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }
die(){ log "FATAL: $*"; exit 1; }

# rsync 3.x if present. macOS /usr/bin/rsync is openrsync (no --sparse) or, on
# older releases, GNU 2.6.9 from 2006. Prefer a modern one when available.
RSYNC="${RSYNC:-}"
if [ -z "$RSYNC" ]; then
  for c in /opt/homebrew/bin/rsync /usr/local/bin/rsync /usr/bin/rsync; do
    [ -x "$c" ] && { RSYNC="$c"; break; }
  done
fi
[ -n "$RSYNC" ] || die "no rsync found"

# --- single-instance lock --------------------------------------------------
# A first seed can run for many hours and overlap its own next scheduled slot.
# mkdir is atomic; macOS has no flock.
LOCK="$LOG_DIR/${HOST_TAG}.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1440 2>/dev/null)" ]; then
    log "stale lock >24h, reclaiming"; rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 1
  else
    log "already running — skipping this run"; exit 0
  fi
fi
trap 'rm -rf "$LOCK"' EXIT INT TERM

log "=== starting $HOST_TAG ${DRY:+(dry run)} ==="

# IdentitiesOnly: authenticate with the backup key and nothing else. An
# agent key on the hub would otherwise mask a broken or unauthorised backup
# key -- the backup keeps working and the restriction stops being tested.
SSH_CMD="ssh -i $SSH_KEY -o IdentitiesOnly=yes -p $SSH_PORT -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new"

# --- preflight -------------------------------------------------------------
# Destination must be a real mounted volume, not a directory left behind where
# one used to be -- otherwise a backup silently fills the hub's system disk.
[ -d "$DEST_ROOT" ] || die "$DEST_ROOT does not exist"
touch "$DEST_ROOT/.snapfabric-wtest" 2>/dev/null || die "$DEST_ROOT not writable — is the backup drive connected?"
rm -f "$DEST_ROOT/.snapfabric-wtest"

# The real hazard is writing to the hub's internal disk when the backup drive
# is absent -- the mount point still exists as a plain directory, so a naive
# "is it writable?" check passes and the system disk quietly fills.
#
# Comparing the backing device against the root filesystem's device catches
# that, while still allowing DEST_ROOT to be a SUBDIRECTORY of the backup
# volume. Requiring DEST_ROOT to be a volume root is too strict and rejects
# perfectly reasonable layouts.
# On macOS, "/" is the SEALED read-only system volume (e.g. disk3s1s1) while all
# user data lives on /System/Volumes/Data (disk3s5). Comparing only against "/"
# therefore passes for any path on the internal disk -- the guard silently does
# nothing on the platform that needs it most. Check every system filesystem.
dest_dev=$(df -P "$DEST_ROOT" 2>/dev/null | awk 'NR==2{print $1}')
[ -n "$dest_dev" ] || die "cannot determine the filesystem backing $DEST_ROOT"

on_system_disk=0
for sysmount in / /System/Volumes/Data /home /var; do
  [ -d "$sysmount" ] || continue
  d=$(df -P "$sysmount" 2>/dev/null | awk 'NR==2{print $1}')
  [ -n "$d" ] && [ "$d" = "$dest_dev" ] && { on_system_disk=1; break; }
done

if [ "$on_system_disk" = "1" ]; then
  if [ "${ALLOW_SYSTEM_DISK:-0}" = "1" ]; then
    log "WARN: $DEST_ROOT is on the system disk ($dest_dev) — permitted by ALLOW_SYSTEM_DISK=1"
  else
    die "$DEST_ROOT is on the system disk ($dest_dev), not a separate backup volume.
       The backup drive is probably not mounted. Set ALLOW_SYSTEM_DISK=1 only if
       you genuinely intend to back up onto the hub's own disk."
  fi
fi

# Sentinel: a file that must exist on the source. Without this, an unmounted
# source presents as an empty directory and --delete propagates the emptiness
# into the new snapshot. Probed via rsync --list-only because a restricted
# backup key permits only `rsync --server --sender`, not arbitrary ssh commands.
if [ -n "${SENTINEL:-}" ]; then
  "$RSYNC" --list-only -e "$SSH_CMD" "$SSH_USER@$SSH_HOST:$SENTINEL" >/dev/null 2>&1 \
    || die "sentinel $SENTINEL missing on $SSH_HOST — source may be unmounted, refusing to run"
  log "sentinel OK: $SENTINEL"
fi

mkdir -p "$HOST_DIR"

# --- hardlink base ---------------------------------------------------------
PREV=""
[ -d "$LATEST" ] && PREV="$(cd "$LATEST" && pwd -P)"
if [ -z "$PREV" ]; then
  # No valid 'latest' means the last run failed. Fall back to the newest
  # existing snapshot even if incomplete: rsync verifies size+mtime per file,
  # so reusing a partial is safe and turns a restart into a resume. Without
  # this, repeated failures each re-copy everything and fill the volume.
  CAND=$(ls -1d "$HOST_DIR"/[0-9]* 2>/dev/null | sort | tail -1)
  [ -n "$CAND" ] && [ -d "$CAND" ] && {
    PREV="$CAND"; log "no valid 'latest'; resuming against partial $(basename "$PREV")"
  }
fi
[ -n "$PREV" ] && log "hardlinking against $(basename "$PREV")" || log "no previous snapshot (first run)"

# --- transfer --------------------------------------------------------------
# -a --numeric-ids only. ACLs (-A) and xattrs (-X) do not survive ext4 -> APFS
# cleanly and generate noise; ownership, permissions and timestamps do.
rc_total=0; partial=0

# SOURCES and EXCLUDES are NEWLINE-delimited, not space-delimited, and are read
# with IFS set to newline only. Unquoted word-splitting on spaces silently tore
# "/srv/My Documents" into two bogus sources -- and "/Volumes/My Drive" is
# an entirely normal macOS path. Note this is a plain for-loop, not a pipe into
# `while read`: a pipeline creates a subshell and rc_total/partial would be lost.
OLDIFS=$IFS
IFS='
'
for src in $SOURCES; do
  IFS=$OLDIFS
  # Skip blank lines so a trailing newline in the config is harmless.
  [ -n "$src" ] || { IFS='
'; continue; }
  rel="${src#/}"
  target="$NEW/$rel"
  mkdir -p "$target"

  # Built explicitly: under bash 3.2 + `set -u`, expanding an empty array is an
  # "unbound variable" error, so this must never be empty when expanded.
  args="-a --numeric-ids --delete --stats"
  [ -n "$DRY" ] && args="$args --dry-run"
  [ "${BWLIMIT:-0}" != "0" ] && args="$args --bwlimit=$BWLIMIT"
  [ -n "$PREV" ] && [ -d "$PREV/$rel" ] && args="$args --link-dest=$PREV/$rel"

  # Build the rsync argv safely. Exclude patterns routinely contain spaces
  # ("/Application Support/"), so they cannot be flattened into one string.
  set -- $args
  IFS='
'
  for pat in ${EXCLUDES:-}; do
    IFS=$OLDIFS
    [ -n "$pat" ] && set -- "$@" "--exclude=$pat"
    IFS='
'
  done
  IFS=$OLDIFS

  log "syncing $src"
  "$RSYNC" "$@" -e "$SSH_CMD" "$SSH_USER@$SSH_HOST:$src/" "$target/" >>"$LOG" 2>&1
  rc=$?
  case $rc in
    0)  ;;
    24) log "note: files vanished during $src (normal on a live system)" ;;
    23) log "WARN: $src partial (rc=23) — see SKIPPED.txt"; partial=1 ;;
    *)  log "ERROR: rsync of $src exited $rc"; rc_total=$rc ;;
  esac
  IFS='
'
done
IFS=$OLDIFS

# --- record what could not be read -----------------------------------------
# Gaps must always be visible. A backup that silently omits files is worse than
# one that fails loudly.
if [ "$partial" = "1" ]; then
  grep "failed to open" "$LOG" 2>/dev/null \
    | sed -E 's/.*failed to open "([^"]+)".*/\1/' | sort -u > "$NEW/SKIPPED.txt"
  n=$(wc -l < "$NEW/SKIPPED.txt" | tr -d ' ')
  log "SKIPPED $n unreadable file(s) — manifest in the snapshot"
  [ "$n" -gt 100 ] 2>/dev/null && { log "ERROR: $n skipped exceeds threshold — treating as failure"; rc_total=23; }
fi

if [ -n "$DRY" ]; then
  log "DRY RUN complete — nothing transferred"; rm -rf "$NEW"; exit $rc_total
fi

# --- failure path ----------------------------------------------------------
if [ "$rc_total" -ne 0 ]; then
  log "run FAILED (rc=$rc_total) — 'latest' still points at the last good snapshot"
  # Deliberately NOT renamed to FAILED_*. Renaming hides the partial from the
  # resume logic above and forces the next run to copy everything again; that
  # is how three ~900GB partials once filled a 2.1TiB volume.
  log "keeping partial $(basename "$NEW") so the next run resumes from it"

  # Retention normally runs only after success, which means a host that never
  # succeeds accumulates partials forever. Prune here too: keep the oldest (the
  # shared hardlink base) plus the two newest.
  cnt=$(ls -1d "$HOST_DIR"/[0-9]* 2>/dev/null | wc -l | tr -d ' ')
  if [ "${cnt:-0}" -gt 3 ]; then
    base=$(ls -1d "$HOST_DIR"/[0-9]* 2>/dev/null | sort | head -1)
    log "failure pruning: $cnt partials, keeping base + 2 newest"
    ls -1d "$HOST_DIR"/[0-9]* 2>/dev/null | sort | tail -n +2 | sed '$d' | sed '$d' | while read -r old; do
      [ "$old" = "$base" ] && continue
      log "  pruning $(basename "$old")"; rm -rf "$old"
    done
  fi

  # Deadlock guard: once the volume is full, every run fails and leaves another
  # partial, which makes it fuller. Drop our own partial rather than compound it.
  pct=$(df -k "$DEST_ROOT" 2>/dev/null | awk 'NR==2{gsub("%","");print $5}')
  if [ -n "${pct:-}" ] && [ "$pct" -ge 95 ] 2>/dev/null; then
    log "volume ${pct}% full — discarding this partial to avoid an ENOSPC deadlock"
    rm -rf "$NEW"
  fi
  exit "$rc_total"
fi

# Prune ONLY snapshot directories newer than 'latest'. Those are by definition
# attempts that were never blessed -- failed runs and gate refusals. Anything at
# or older than 'latest' is real history and belongs to normal retention, which
# runs only after a successful bless (constraint 7). Without this, every refused
# run leaves its directory behind: on one estate 500 accumulated in 28 days.
#
# The newest unblessed directory is kept deliberately -- it is the resume base
# for the next run, which is why failed runs are not renamed away (constraint 6).
prune_unblessed(){
  local keep newest d
  keep=$(readlink "$LATEST" 2>/dev/null | sed 's|.*/||')
  [ -n "$keep" ] || return 0          # nothing blessed yet: keep everything
  # shellcheck disable=SC2010  # names are strictly YYYY-MM-DD_HHMMSS; the grep enforces it
  newest=$(ls -1 "$HOST_DIR" 2>/dev/null | grep '^[0-9][0-9][0-9][0-9]-' | sort | tail -1)
  # shellcheck disable=SC2010
  ls -1 "$HOST_DIR" 2>/dev/null | grep '^[0-9][0-9][0-9][0-9]-' | sort | while read -r d; do
    [ "$d" \> "$keep" ] || continue
    [ "$d" = "$newest" ] && continue
    log "  pruning unblessed $d"
    rm -rf "${HOST_DIR:?}/$d"
  done
}

# --- size gate -------------------------------------------------------------
# Measure BEFORE blessing. Both halves of this were learned the hard way.
#
# 1. Ordering. This block used to run AFTER 'latest' had already been moved, so
#    it could only ever describe a bad snapshot that was already the reference
#    point. A run that transferred nothing because the volume was full logged
#    "0% of source" and became 'latest' anyway. Every later run then hardlinked
#    against an empty base, re-sent the whole source, ran for hours and failed:
#    the empty snapshot caused the slowness that caused the failures. Nine of
#    twenty-nine snapshots on that host were stubs before anyone noticed.
#
# 2. Baseline. The comparison must be against a HIGH-WATER MARK of recent
#    accepted sizes, never the immediately preceding snapshot. Once a single
#    stub has been blessed, the predecessor IS the stub: a 60GB truncated
#    snapshot measured against a 29MB stub looks like a 2000x improvement and
#    passes. Measured against the high-water mark it is 13%, and is refused.
#    One bad acceptance must not lower the bar for every run after it.
#
# Source size is deliberately not part of the decision -- it counts excluded
# trees, so it moves for reasons unrelated to backup health (deleting one large
# log file moved it by 335GB on the estate this was developed against).
# Snapshot
# growth relative to the mark is the honest signal.
SIZES="$HOST_DIR/.accepted-sizes"
sz=$(du -sk "$NEW" 2>/dev/null | cut -f1)
# Measured here, not in the inflation guard below, because the no-baseline floor
# needs it: computing it after the gate meant the floor silently never fired.
psz=""
[ -n "${PREV:-}" ] && psz=$(du -sk "$PREV" 2>/dev/null | cut -f1)
hwm=$(awk '/^[0-9]+$/ { if ($1 > m) m = $1 } END { print m + 0 }' "$SIZES" 2>/dev/null)

if [ "${hwm:-0}" -gt 0 ] 2>/dev/null && [ -n "${sz:-}" ]; then
  hpct=$(( sz * 100 / hwm ))
  if [ "$hpct" -lt "${MIN_SIZE_PCT:-50}" ] 2>/dev/null; then
    if [ "${ALLOW_SHRINK:-0}" = "1" ]; then
      log "size gate: ${hpct}% of high-water mark — accepted anyway, ALLOW_SHRINK=1"
    else
      log "REFUSING to bless this snapshot: it is ${hpct}% of the high-water mark"
      log "  ($(( sz / 1024 ))MB vs $(( hwm / 1024 ))MB). A backup this much smaller than"
      log "  recent good ones did not finish. 'latest' is unchanged."
      log "  If the shrink is genuine, re-run with ALLOW_SHRINK=1 to accept it."
      pct=$(df -k "$HOST_DIR" 2>/dev/null | awk 'NR==2{gsub("%",""); print $5}')
      if [ -n "${pct:-}" ] && [ "$pct" -ge 95 ] 2>/dev/null; then
        log "  volume ${pct}% full — discarding the rejected snapshot to avoid ENOSPC"
        rm -rf "$NEW"
      fi
      prune_unblessed
      exit 1
    fi
  else
    log "size gate: ${hpct}% of high-water mark — OK"
  fi
else
  # No high-water mark yet -- the one moment the gate has nothing to compare
  # against. Fall back to the previous snapshot as a floor.
  #
  # This originally only declined to RECORD a thin run as the baseline while
  # still blessing it as 'latest'. That is incoherent, and it happened for real
  # in real use: a complete snapshot was replaced as 'latest' by one
  # 43% of its size, because no baseline had been established yet. A run too
  # thin to be trusted as a reference is too thin to be the restore point. The
  # two are now one decision.
  if [ "${ALLOW_SHRINK:-0}" != "1" ] && [ -n "${psz:-}" ] && [ "$psz" -gt 0 ] 2>/dev/null \
     && [ -n "${sz:-}" ] && [ "$(( sz * 100 / psz ))" -lt 50 ] 2>/dev/null; then
    log "REFUSING to bless this snapshot: at $(( sz * 100 / psz ))% of the previous one"
    log "  it is too thin to trust, and there is no high-water mark yet to judge it"
    log "  against. 'latest' is unchanged. If the shrink is genuine, re-run with"
    log "  ALLOW_SHRINK=1."
    prune_unblessed
    exit 1
  fi
  log "size gate: no baseline recorded yet — this run establishes it"
fi

# --- inflation guard -------------------------------------------------------
# The other direction: rsync without --sparse writes a sparse file's zero blocks
# out in full. Docker.raw once turned 9.7GB into 926GB and filled the drive.
if [ -n "${PREV:-}" ] && [ -n "${sz:-}" ]; then
  if [ -n "${psz:-}" ] && [ "$psz" -gt 0 ] 2>/dev/null; then
    ratio=$(( sz * 100 / psz ))
    [ "$ratio" -gt 200 ] 2>/dev/null && {
      log "WARN: snapshot is ${ratio}% of the previous one — suspect a SPARSE FILE."
      log "      find it:  du -sk $NEW/* | sort -rn | head"
      log "      then add it to EXCLUDES; rsync cannot handle sparse files here."
    }
  fi
fi

ln -sfn "$NEW" "$LATEST" || die "could not update 'latest'"
log "snapshot complete: $NEW"

# Record the accepted size, keeping the last 5. The gate takes the MAX, so a
# single ALLOW_SHRINK acceptance cannot drag the baseline down by itself, and an
# obsolete mark ages out naturally after five good runs.
# Anything that got here passed the gate above, including the no-baseline floor,
# so it is fit to be the reference as well as the restore point. Deliberately
# the same decision.
#
# ALLOW_SHRINK REPLACES the scale rather than joining it. Appending deadlocks:
# the gate takes the MAX of the last five, and a refused run records nothing, so
# stale large entries can never rotate out and every run after the override is
# refused again. An earlier comment here claimed the mark "decays out naturally
# after five good runs" -- it cannot, because a refused run is not a good run.
# On a real estate this cost 28 days of backups after a deliberate, permanent
# scope reduction: one ALLOW_SHRINK run was accepted, and every run after it was
# measured against the four 234GB entries still sitting in the file.
if [ -n "${sz:-}" ]; then
  if [ "${ALLOW_SHRINK:-0}" = "1" ]; then
    printf '%s\n' "$sz" > "$SIZES"
    log "ALLOW_SHRINK: baseline RESET to $(( sz / 1024 ))MB"
  else
    printf '%s\n' "$sz" >> "$SIZES"
    tail -5 "$SIZES" > "$SIZES.tmp" 2>/dev/null && mv "$SIZES.tmp" "$SIZES"
  fi
fi

# --- retention -------------------------------------------------------------
# Pure shell. python3 is NOT a dependency of the agents: on macOS /usr/bin/python3
# is a stub that triggers an Xcode Command Line Tools prompt, so relying on it
# would make a backup agent fail on a fresh machine. Python is optional and only
# used by the installer TUI.
#
# Tiers: every snapshot for KEEP_HOURLY hours, then one per day for KEEP_DAILY
# days, one per week for KEEP_WEEKLY weeks, one per month for KEEP_MONTHLY months.

epoch_of(){
  local n="$1"
  date -j -f "%Y-%m-%d_%H%M%S" "$n" +%s 2>/dev/null && return 0
  date -d "$(echo "$n" | sed 's/_/ /; s/\(..\)\(..\)\(..\)$/\1:\2:\3/')" +%s 2>/dev/null && return 0
  echo 0
}

now_e=$(date +%s)
seen_d=""; seen_w=""; seen_m=""; kept=0; total=0

# Newest first, so the most recent snapshot in each period is the one retained.
# shellcheck disable=SC2010  # names are strictly YYYY-MM-DD_HHMMSS; the grep enforces it
for snap in $(ls -1 "$HOST_DIR" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$' | sort -r); do
  total=$((total+1))
  e=$(epoch_of "$snap"); [ "$e" -eq 0 ] 2>/dev/null && { log "retention: cannot parse $snap, keeping"; kept=$((kept+1)); continue; }
  age_h=$(( (now_e - e) / 3600 ))
  keep=0

  if [ "$age_h" -le "$((KEEP_HOURLY))" ]; then
    keep=1
  else
    day=${snap%_*}
    if [ "$age_h" -le "$((KEEP_DAILY * 24))" ]; then
      case " $seen_d " in *" $day "*) : ;; *) seen_d="$seen_d $day"; keep=1 ;; esac
    fi
    if [ "$keep" -eq 0 ] && [ "$age_h" -le "$((KEEP_WEEKLY * 168))" ]; then
      # %G, not %Y: %V is the ISO week number, whose year is the ISO week-year.
      # Pairing it with the calendar year puts the days either side of 1 January
      # in the same bucket ("2026-01" for both the last week of 2025 and the
      # first of 2026), so one weekly snapshot a year is silently discarded.
      wk=$(date -j -f "%s" "$e" +%G-%V 2>/dev/null || date -d "@$e" +%G-%V 2>/dev/null)
      case " $seen_w " in *" $wk "*) : ;; *) seen_w="$seen_w $wk"; keep=1 ;; esac
    fi
    if [ "$keep" -eq 0 ] && [ "$age_h" -le "$((KEEP_MONTHLY * 744))" ]; then
      mo=${snap%-*}; mo=${mo%-*}
      case " $seen_m " in *" $mo "*) : ;; *) seen_m="$seen_m $mo"; keep=1 ;; esac
    fi
  fi

  if [ "$keep" -eq 1 ]; then
    kept=$((kept+1))
  else
    # Never prune the snapshot 'latest' points at, whatever the tiers say.
    if [ "$HOST_DIR/$snap" = "$PREV" ]; then
      log "retention: $snap is the current hardlink base, keeping"; kept=$((kept+1)); continue
    fi
    log "retention: pruning $snap"; rm -rf "${HOST_DIR:?}/${snap:?}"
  fi
done
log "retention: kept $kept of $total snapshots"

log "=== finished $HOST_TAG ==="
