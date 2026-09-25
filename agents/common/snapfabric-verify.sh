#!/bin/bash
# snapfabric verify — prove a restore works, by doing one.
#
#   usage: snapfabric-verify.sh [--conf DIR] [--host TAG] [--samples N] [--plain]
#
# RUNS ON THE HUB. Read-only: it copies files OUT of a snapshot into a temp
# directory and pulls the corresponding source files down to compare. It never
# writes to the backup drive and never writes to a backed-up host.
#
# WHY THIS COMMAND EXISTS
# A snapshot count proves a job ran. A green scheduler proves it was invoked.
# Neither proves the bytes are there and readable. The only evidence that a
# backup is a backup is restoring from it and checking the content, so that is
# what this does: pull a sample of files out of the snapshot, fetch the same
# files from the source, and compare SHA-256.
#
# HANDLING LEGITIMATE DRIFT
# A source file may have changed since the snapshot was taken; that is normal
# and is NOT a verification failure. A mismatch is only reported as a failure
# when the source is NOT newer than the backed-up copy -- i.e. when the two
# should agree and do not.
#
# Exit: 0 everything verified, 1 a real mismatch, 2 usage/config error.

set -uo pipefail


CONF_DIR="${SNAPFABRIC_CONF_DIR:-$HOME/.config/snapfabric}"
ONLY_HOST=""; SAMPLES=3; PLAIN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --conf)    CONF_DIR="${2:-}"; shift 2 ;;
    --host)    ONLY_HOST="${2:-}"; shift 2 ;;
    --samples) SAMPLES="${2:-3}"; shift 2 ;;
    --plain)   PLAIN=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "usage: $0 [--conf DIR] [--host TAG] [--samples N] [--plain]" >&2; exit 2 ;;
  esac
done
case "$SAMPLES" in ''|*[!0-9]*) echo "--samples must be a number" >&2; exit 2 ;; esac

B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
{ [ -t 1 ] && [ "$PLAIN" -eq 0 ]; } || { B=""; D=""; G=""; Y=""; R=""; N=""; }

step(){ printf "    ${D}%s${N}\n" "$*"; }
good(){ printf "    ${G}✓${N} %s\n" "$*"; }
warn(){ printf "    ${Y}!${N} %s\n" "$*"; }
bad(){  printf "    ${R}✗${N} %s\n" "$*"; }
die(){  printf "${R}✗ %s${N}\n" "$*" >&2; exit 2; }

# Portable SHA-256. macOS has shasum, most Linuxes have sha256sum, and a hub
# missing both must say so rather than silently verifying nothing.
if command -v shasum >/dev/null 2>&1;      then sha(){ shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }
elif command -v sha256sum >/dev/null 2>&1; then sha(){ sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
else die "no shasum or sha256sum on this hub — cannot verify anything"
fi

# Prefer a modern rsync, exactly as the engine does, then FEATURE-DETECT rather
# than assume. macOS /usr/bin/rsync is openrsync, which rejects -s
# (--protect-args) outright -- the same trap as its missing --sparse. Capture the
# help text before grepping it: rsync exits non-zero on --help and `set -o
# pipefail` would report the pipeline as failed even when grep matched
# (constraint 20).
RSYNC="${RSYNC:-}"
if [ -z "$RSYNC" ]; then
  for c in /opt/homebrew/bin/rsync /usr/local/bin/rsync /usr/bin/rsync; do
    [ -x "$c" ] && { RSYNC="$c"; break; }
  done
fi
[ -n "$RSYNC" ] || die "no rsync found on this hub"
_rsync_help=$("$RSYNC" --help 2>&1 || true)
PROTECT=""
printf '%s' "$_rsync_help" | grep -q -- '--protect-args' && PROTECT="-s"

# Portable "seconds since epoch of this file's mtime".
if stat -f %m . >/dev/null 2>&1; then mtime(){ stat -f %m "$1" 2>/dev/null; }
else                                 mtime(){ stat -c %Y "$1" 2>/dev/null; }
fi
if stat -f %i . >/dev/null 2>&1; then inode(){ stat -f %i "$1" 2>/dev/null; }
else                                 inode(){ stat -c %i "$1" 2>/dev/null; }
fi

HUB_CONF="$CONF_DIR/snapfabric.conf"
[ -r "$HUB_CONF" ] || die "no config at $HUB_CONF"
# shellcheck disable=SC1090
. "$HUB_CONF"
: "${BACKUP_ROOT:?config must set BACKUP_ROOT}"
: "${BACKUP_HOSTS:?config must set BACKUP_HOSTS}"

[ -d "$BACKUP_ROOT" ] || die "$BACKUP_ROOT does not exist — is the backup drive connected?"

TMP=$(mktemp -d) || die "cannot create a temp directory"
trap 'rm -rf "$TMP"' EXIT INT TERM

printf "${B}snapfabric verify${N}  ${D}%s${N}\n\n" "$BACKUP_ROOT"

total_ok=0; total_bad=0; total_drift=0; hosts_bad=""

for TAG in $BACKUP_HOSTS; do
  [ -n "$ONLY_HOST" ] && [ "$ONLY_HOST" != "$TAG" ] && continue
  printf "${B}%s${N}\n" "$TAG"

  HCONF="$CONF_DIR/hosts/$TAG.conf"
  if [ ! -r "$HCONF" ]; then bad "no host config at $HCONF"; hosts_bad="$hosts_bad $TAG"; echo; continue; fi

  SSH_USER=""; SSH_HOST=""; SSH_KEY=""; SSH_PORT=""
  # shellcheck disable=SC1090
  . "$HCONF"
  : "${SSH_KEY:=$HOME/.ssh/snapfabric_$TAG}"
  : "${SSH_PORT:=22}"
  # IdentitiesOnly: authenticate with the backup key and nothing else. An
# agent key on the hub would otherwise mask a broken or unauthorised backup
# key -- the backup keeps working and the restriction stops being tested.
SSH_CMD="ssh -i $SSH_KEY -o IdentitiesOnly=yes -p $SSH_PORT -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new"

  HOST_DIR="$BACKUP_ROOT/$TAG"
  if [ ! -d "$HOST_DIR" ]; then bad "no snapshots at all for $TAG"; hosts_bad="$hosts_bad $TAG"; echo; continue; fi

  # Newest dated snapshot. 'latest' is preferred but may be a dangling symlink
  # after a failed run, in which case fall back rather than reporting nothing.
  SNAP=""
  [ -d "$HOST_DIR/latest" ] && SNAP="$(cd "$HOST_DIR/latest" && pwd -P)"
  if [ -z "$SNAP" ]; then
    # shellcheck disable=SC2010  # names are strictly dated; the pattern enforces it
    SNAP=$(ls -1d "$HOST_DIR"/[0-9]* 2>/dev/null | sort | tail -1)
    [ -n "$SNAP" ] && warn "no valid 'latest' — verifying newest snapshot $(basename "$SNAP")"
  fi
  if [ -z "$SNAP" ] || [ ! -d "$SNAP" ]; then
    bad "no usable snapshot for $TAG"; hosts_bad="$hosts_bad $TAG"; echo; continue
  fi

  age_s=$(( $(date +%s) - $(mtime "$SNAP") ))
  step "snapshot $(basename "$SNAP"), $(( age_s / 3600 ))h old"

  # Sample real files. Small ones on purpose: verify should be cheap enough to
  # run often, and a 4 GB re-pull to check one checksum is a reason not to.
  find "$SNAP" -type f -size +0 -size -2048k 2>/dev/null | head -n "$SAMPLES" > "$TMP/samples"
  if [ ! -s "$TMP/samples" ]; then
    warn "no files under 2 MB to sample — snapshot may be empty or all-large"
    echo; continue
  fi

  h_ok=0; h_bad=0; h_drift=0
  while IFS= read -r snapfile; do
    [ -n "$snapfile" ] || continue
    rel="${snapfile#"$SNAP"}"          # /private/tmp/... -> as stored
    srcpath="$rel"                      # snapshot mirrors absolute source paths

    h_snap=$(sha "$snapfile")
    if [ -z "$h_snap" ]; then
      bad "cannot read $rel out of the snapshot"    # unreadable backup = no backup
      h_bad=$((h_bad+1)); continue
    fi

    # Pull the source copy down. --protect-args keeps a path with spaces in one
    # piece where it exists; the restricted key permits exactly this operation
    # (rsync --server --sender).
    rm -rf "$TMP/pull"; mkdir -p "$TMP/pull"
    if ! "$RSYNC" -a ${PROTECT:+"$PROTECT"} -e "$SSH_CMD" \
         "$SSH_USER@$SSH_HOST:$srcpath" "$TMP/pull/" >"$TMP/rsync.err" 2>&1; then
      warn "cannot fetch $rel from the source: $(tail -1 "$TMP/rsync.err")"
      h_drift=$((h_drift+1)); continue
    fi
    pulled=$(find "$TMP/pull" -type f | head -1)
    h_src=$(sha "$pulled")

    if [ "$h_snap" = "$h_src" ]; then
      good "$rel"
      h_ok=$((h_ok+1))
    else
      # Only a failure if the two SHOULD agree. A source edited after the
      # snapshot is expected drift, not a corrupt backup.
      m_snap=$(mtime "$snapfile"); m_src=$(mtime "$pulled")
      if [ -n "$m_src" ] && [ -n "$m_snap" ] && [ "$m_src" -gt "$m_snap" ]; then
        step "$rel changed on the source since this snapshot (expected)"
        h_drift=$((h_drift+1))
      else
        bad "$rel MISMATCH — backup and source differ and the source is not newer"
        h_bad=$((h_bad+1))
      fi
    fi
  done < "$TMP/samples"

  # Hardlink rotation: an unchanged file must share an inode with the previous
  # snapshot. If it does not, every snapshot is a full copy and the drive fills
  # at N times the expected rate -- silently, because backups still "work".
  # shellcheck disable=SC2010
  prev=$(ls -1d "$HOST_DIR"/[0-9]* 2>/dev/null | sort | tail -2 | head -1)
  if [ -n "$prev" ] && [ "$prev" != "$SNAP" ] && [ -d "$prev" ]; then
    shared=0; checked=0
    while IFS= read -r snapfile; do
      rel="${snapfile#"$SNAP"}"
      [ -f "$prev$rel" ] || continue
      checked=$((checked+1))
      [ "$(inode "$snapfile")" = "$(inode "$prev$rel")" ] && shared=$((shared+1))
    done < "$TMP/samples"
    if [ "$checked" -eq 0 ]; then
      step "no common files with the previous snapshot to check hardlinking"
    elif [ "$shared" -eq 0 ]; then
      bad "no sampled file is hardlinked to $(basename "$prev") — snapshots are full copies"
      h_bad=$((h_bad+1))
    else
      good "hardlinked to $(basename "$prev") ($shared/$checked sampled files share an inode)"
    fi
  fi

  printf "    %d verified, %d drifted, %d failed\n" "$h_ok" "$h_drift" "$h_bad"
  total_ok=$((total_ok+h_ok)); total_bad=$((total_bad+h_bad)); total_drift=$((total_drift+h_drift))
  [ "$h_bad" -gt 0 ] && hosts_bad="$hosts_bad $TAG"
  echo
done

printf "${B}summary${N}\n"
printf "  %d files verified by SHA-256, %d drifted, %d failed\n" "$total_ok" "$total_drift" "$total_bad"
if [ -n "$hosts_bad" ]; then
  printf "  ${R}problems on:%s${N}\n" "$hosts_bad"
  exit 1
fi
if [ "$total_ok" -eq 0 ]; then
  printf "  ${Y}nothing was actually verified${N} — treat this as unproven, not as a pass\n"
  exit 1
fi
printf "  ${G}restore verified${N}\n"
