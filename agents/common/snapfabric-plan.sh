#!/bin/bash
# snapfabric plan — decide what gets backed up, where, and how often.
#
#   usage: snapfabric-plan.sh [--out DIR] [--force] [--plain]
#
# WRITES CONFIG FILES AND NOTHING ELSE. No keys are generated, no directory is
# created on the backup drive, no remote host is contacted. `provision` is the
# first command that touches anything, and it only ever acts on what this wrote.
#
# Output:
#   <out>/snapfabric.conf        hub-level: drive, host list, labels, retention
#   <out>/hosts/<tag>.conf       one per host: what the snapshot engine reads
#
# Both are mode 0600 from creation. They are sourced as shell, so write access
# to either is equivalent to code execution -- see docs/SECURITY.md. Everything
# the operator types is validated before it lands in them.
#
# Pure shell, bash 3.2. Prompts read from stdin, so the whole flow can be
# driven from a here-doc; tests/test-constraints.sh does exactly that.

set -uo pipefail
umask 077   # everything this writes holds infrastructure detail; default it tight

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib-validate.sh
. "$HERE/lib-validate.sh" || { echo "plan: cannot load lib-validate.sh" >&2; exit 1; }
# shellcheck source=lib-mounts.sh
. "$HERE/lib-mounts.sh"   || { echo "plan: cannot load lib-mounts.sh" >&2; exit 1; }
# shellcheck source=lib-host.sh
. "$HERE/lib-host.sh" || { echo "plan: cannot load lib-host.sh" >&2; exit 1; }

OUT="${SNAPFABRIC_CONF_DIR:-$HOME/.config/snapfabric}"
FORCE=0; PLAIN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out)   OUT="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --plain) PLAIN=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "usage: $0 [--out DIR] [--force] [--plain]" >&2; exit 2 ;;
  esac
done

B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
{ [ -t 1 ] && [ "$PLAIN" -eq 0 ]; } || { B=""; D=""; G=""; Y=""; R=""; N=""; }

# shellcheck disable=SC2120  # called bare for a blank line, and with text
say(){  printf '%s\n' "$*"; }
note(){ printf "${D}%s${N}\n" "$*"; }
warn(){ printf "${Y}!  %s${N}\n" "$*" >&2; }
bad(){  printf "${R}✗  %s${N}\n" "$*" >&2; }
die(){  bad "$*"; exit 1; }

# --- prompting ---------------------------------------------------------------
# Every answer comes from stdin. On EOF the default is taken, and a value that
# fails validation is retried a bounded number of times -- an unattended run
# must fail loudly rather than spin forever against a closed stdin.
# These locals carry an sf_ prefix on purpose. The caller passes the NAME of the
# variable to fill, and an earlier version used plain __a for both the callee's
# scratch variable and ask_yn's target -- so `eval "$__v=..."` assigned to the
# callee's own local and the answer never reached the caller. Every y/n prompt
# silently took the else branch. Do not reuse these names in a caller.
ask(){ # ask <varname> <prompt> [default]
  local __sf_v="$1" __sf_p="$2" __sf_d="${3:-}" __sf_a
  if [ -n "$__sf_d" ]; then printf "%s ${D}[%s]${N}: " "$__sf_p" "$__sf_d"
  else                      printf "%s: " "$__sf_p"; fi
  IFS= read -r __sf_a || { __sf_a=""; printf '\n'; }
  [ -z "$__sf_a" ] && __sf_a="$__sf_d"
  eval "$__sf_v=\$__sf_a"
}

ask_valid(){ # ask_valid <validator> <varname> <prompt> [default]
  local __sf_f="$1" __sf_n="$2" __sf_q="$3" __sf_def="${4:-}" __sf_try=0 __sf_x
  while :; do
    ask "$__sf_n" "$__sf_q" "$__sf_def"
    eval "__sf_x=\$$__sf_n"
    "$__sf_f" "$__sf_x" && return 0
    __sf_try=$((__sf_try+1))
    case "$__sf_f" in
      safe_token) warn "must be a plain word: no spaces, quotes or shell characters" ;;
      safe_path)  warn "path may not contain \" \$ \` \\ or a newline" ;;
      safe_int)   warn "must be a whole number" ;;
      *)          warn "invalid value" ;;
    esac
    [ "$__sf_try" -ge 3 ] && die "giving up on '$__sf_q' after 3 invalid answers"
  done
}

ask_yn(){ # ask_yn <prompt> <default y|n> -> rc 0 for yes
  local __sf_yn=""; ask __sf_yn "$1 ${D}(y/n)${N}" "$2"
  case "$__sf_yn" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# --- adoption: read an existing config as defaults ----------------------------
# Renaming a live scheduler label is disruptive, so an existing setup supplies
# the defaults and every change is shown as a diff before anything is replaced.
HUB_CONF="$OUT/snapfabric.conf"
ADOPTING=0
HUB_USER=""; HUB_HOST=""; HUB_KEY=""; HUB_PORT=""; BACKUP_ROOT=""; MANAGED_VOLUMES=""
BACKUP_HOSTS=""; PULL_LABEL_PREFIX=""
# PUSH_HOSTS and FRESHNESS are deliberately NOT seeded from an existing config:
# both are recomputed from the host answers, and inheriting an old FRESHNESS
# would defeat the point of deriving it from the schedule.
BWLIMIT=0; KEEP_HOURLY=24; KEEP_DAILY=30; KEEP_WEEKLY=8; KEEP_MONTHLY=12
# shellcheck disable=SC2088  # deliberate: expanded by the HUB's shell, not this one
REMOTE_CMD="~/bin/snapfabric-remote"
ADVERTISER_PATTERN=""; ADVERTISER_LABEL=""; WATCHDOG_HOST=""; WATCHDOG_KEY=""

if [ -r "$HUB_CONF" ]; then
  ADOPTING=1
  # shellcheck disable=SC1090
  . "$HUB_CONF"
fi

TMP=$(mktemp -d) || die "cannot create a temp directory"
trap 'rm -rf "$TMP"' EXIT INT TERM
MIDX="$TMP/mounts.idx"

printf "${B}snapfabric plan${N}  ${D}writes config only — nothing is provisioned${N}\n"
[ "$ADOPTING" -eq 1 ] && note "adopting existing config at $HUB_CONF; press return to keep a value"
say

# --- the hub -----------------------------------------------------------------
printf "${B}The hub${N} — the machine the backup drive is attached to.\n"
ask_valid safe_token HUB_USER "  login user on the hub" "${HUB_USER:-$(id -un)}"
ask_valid safe_token HUB_HOST "  hub address (IP or hostname)" "${HUB_HOST:-}"
ask_valid safe_path  HUB_KEY  "  SSH key used to reach the hub" "${HUB_KEY:-$HOME/.ssh/snapfabric_hub}"
say

# --- the drive ---------------------------------------------------------------
printf "${B}The backup drive${N}\n"
case "$(uname -s)" in Darwin) _root_hint="/Volumes/Backups" ;; *) _root_hint="/srv/backups" ;; esac

# Offer what is actually mounted rather than making the operator recall a path.
# Only meaningful when plan runs ON the hub; say so rather than presenting this
# machine's disks as if they were the hub's.
# Render ONCE into a file. Calling render_mount_menu in the `if` and again in
# the body printed the whole list twice.
if scan_mounts_local | render_mount_menu "$MIDX" > "$TMP/menu.local"; then
  note "  Mounted filesystems on THIS machine (external drives first):"
  cat "$TMP/menu.local"
  note "  Pick a number, or type any path — including one on another machine."
fi
while :; do
  ask _br "  snapshot root on the hub" "${BACKUP_ROOT:-$_root_hint}"
  _br=$(resolve_mount_choice "$MIDX" "$_br")
  if [ -z "$_br" ]; then warn "no such entry in the list"; continue; fi
  safe_path "$_br" || { warn "path may not contain \" \$ \` \\ or a newline"; continue; }
  BACKUP_ROOT="$_br"; break
done

# Validate now rather than at first backup, but only when this is actually
# running on the hub -- planning from a laptop cannot see the hub's disks.
if [ -d "$BACKUP_ROOT" ]; then
  dest_dev=$(df -P "$BACKUP_ROOT" 2>/dev/null | awk 'NR==2{print $1}')
  on_system=0
  for sysmount in / /System/Volumes/Data /home /var; do
    [ -d "$sysmount" ] || continue
    d=$(df -P "$sysmount" 2>/dev/null | awk 'NR==2{print $1}')
    [ -n "$d" ] && [ "$d" = "$dest_dev" ] && { on_system=1; break; }
  done
  if [ "$on_system" -eq 1 ]; then
    bad "$BACKUP_ROOT is on this machine's system disk ($dest_dev)."
    note "   If the drive is simply not plugged in, its mount point still exists"
    note "   as an ordinary directory and backups would fill your boot volume."
    note "   The engine refuses to run against it. Plug the drive in, or choose"
    note "   a path on it."
    ask_yn "  keep this path anyway?" n || die "aborted — no config written"
  else
    printf "  ${G}✓${N} on %s, not the system disk\n" "$dest_dev"
  fi
  if command -v diskutil >/dev/null 2>&1; then
    if diskutil info "$BACKUP_ROOT" >/dev/null 2>&1; then
      printf "  ${G}✓${N} a real mounted volume\n"
    else
      warn "$BACKUP_ROOT exists but diskutil does not know it as a volume —"
      warn "  that is what a stale mount point looks like after a drive re-enumerates."
    fi
  fi
else
  note "  not present on this machine; it will be checked on the hub at provision time"
fi

_vol_hint="$MANAGED_VOLUMES"
if [ -z "$_vol_hint" ]; then
  case "$BACKUP_ROOT" in /Volumes/*) _vol_hint="${BACKUP_ROOT#/Volumes/}"; _vol_hint="${_vol_hint%%/*}" ;; *) _vol_hint="" ;; esac
fi
# Asked unconditionally, not just on macOS: the verb dispatcher requires it, and
# a prompt that appears on one platform and not another makes the whole flow
# impossible to drive from a script — including from the test suite.
note "  Volumes the tooling may mount or repair. Anything not listed is refused."
note "  One per line, blank to finish. Spaces are fine — Apple names Time Machine"
note "  drives are named \"Backups of <your computer>\" by default."
_mv_default="${_vol_hint:-Backups}"
_mv_list=""
while :; do
  ask _mv "  managed volume name" "$_mv_default"
  _mv_default=""            # offered once, so a blank answer ends the list
  [ -z "$_mv" ] && break
  if ! safe_arg "$_mv"; then warn "volume name may not contain shell characters"; continue; fi
  case "
$_mv_list
" in *"
$_mv
"*) warn "already listed"; continue ;; esac
  _mv_list="${_mv_list:+$_mv_list
}$_mv"
done
[ -n "$_mv_list" ] || die "at least one managed volume is required"
MANAGED_VOLUMES="$_mv_list"
say

# --- hosts --------------------------------------------------------------------
printf "${B}Hosts${N} — what to back up. Run ${D}snapfabric discover${N} first if you need the list.\n"
[ "$ADOPTING" -eq 1 ] && [ -n "$BACKUP_HOSTS" ] && note "  currently: $BACKUP_HOSTS"
say

NEW_HOSTS=""; NEW_PUSH=""; NEW_FRESH=""


while :; do
  ask _add "Add a host? ${D}(name, or blank to finish)${N}" ""
  [ -z "$_add" ] && break
  safe_token "$_add" || { warn "host tag must be a plain word"; continue; }
  case " $NEW_HOSTS " in *" $_add "*) warn "$_add is already in the plan"; continue ;; esac

  # The prompting itself lives in lib-host.sh because `add-node` needs the
  # identical flow against an existing fabric. Read the result back out of the
  # files it wrote rather than relying on variables leaking out of the function.
  prompt_host "$_add" "$TMP" || { warn "could not add $_add"; continue; }
  P_MODE=""; P_FRESH=""
  # shellcheck disable=SC1090
  . "$TMP/h.$_add"
  NEW_HOSTS="${NEW_HOSTS:+$NEW_HOSTS }$_add"
  [ "$P_MODE" = push ] && NEW_PUSH="${NEW_PUSH:+$NEW_PUSH }$_add"
  NEW_FRESH="${NEW_FRESH:+$NEW_FRESH }$_add:$P_FRESH"
  say
done

[ -n "$NEW_HOSTS" ] || die "no hosts in the plan — nothing to write"

# --- scheduler labels and retention -------------------------------------------
say
printf "${B}Scheduling and retention${N}\n"
note "  Each host's job is named <prefix>.<host>. If you are adopting an existing"
note "  setup, keep the prefix it already uses — renaming live jobs is disruptive."
ask_valid safe_token PULL_LABEL_PREFIX "  scheduler label prefix" "${PULL_LABEL_PREFIX:-local.snapfabric.pull}"
ask_valid safe_int   KEEP_HOURLY  "  keep hourly snapshots"  "${KEEP_HOURLY:-24}"
ask_valid safe_int   KEEP_DAILY   "  keep daily snapshots"   "${KEEP_DAILY:-30}"
ask_valid safe_int   KEEP_WEEKLY  "  keep weekly snapshots"  "${KEEP_WEEKLY:-8}"
ask_valid safe_int   KEEP_MONTHLY "  keep monthly snapshots" "${KEEP_MONTHLY:-12}"
ask_valid safe_int   BWLIMIT      "  bandwidth cap in KB/s (0 = unlimited)" "${BWLIMIT:-0}"

# --- summary -------------------------------------------------------------------
say
printf "${B}Plan${N}\n"
printf "  hub          %s@%s\n" "$HUB_USER" "$HUB_HOST"
printf "  drive        %s\n" "$BACKUP_ROOT"
printf "  retention    %sh / %sd / %sw / %sm\n" "$KEEP_HOURLY" "$KEEP_DAILY" "$KEEP_WEEKLY" "$KEEP_MONTHLY"
say
printf "  ${B}%-12s %-8s %-9s %-7s %s${N}\n" "HOST" "MODE" "SCHEDULE" "STALE" "SOURCES"
for t in $NEW_HOSTS; do
  # shellcheck disable=SC1090
  ( . "$TMP/h.$t"
    printf "  %-12s %-8s %-9s %-7s %s\n" "$P_TAG" "$P_MODE" "$P_SCHED" "${P_FRESH}h" \
      "$(tr '\n' ' ' < "$TMP/src.$P_TAG")" )
done
say

if [ "$FORCE" -ne 1 ]; then
  ask_yn "Write this plan?" y || die "aborted — nothing written"
fi

# --- write ---------------------------------------------------------------------
# Written to a temp file at mode 0600 and moved into place, so the config is
# never briefly readable by anyone else and never half-written.
mkdir -p "$OUT/hosts" || die "cannot create $OUT/hosts"
chmod 700 "$OUT" 2>/dev/null || true

write_conf(){ # write_conf <target> <tmpfile>
  local target="$1" src="$2"
  if [ -f "$target" ] && ! cmp -s "$src" "$target"; then
    printf "\n${B}%s${N} would change:\n" "$target"
    diff -u "$target" "$src" | sed 's/^/  /'
    if [ "$FORCE" -ne 1 ]; then
      ask_yn "  replace it?" y || { note "  kept existing $target"; return 0; }
    fi
  fi
  chmod 600 "$src"
  mv "$src" "$target" || die "cannot write $target"
  printf "  ${G}✓${N} %s\n" "$target"
}

HUB_TMP="$TMP/hub.conf"
: > "$HUB_TMP"; chmod 600 "$HUB_TMP"
{
cat <<'EOF'
# snapfabric configuration — written by `snapfabric plan`.
#
# Sourced as shell, so write access to this file is equivalent to code
# execution. Keep it mode 0600. See docs/SECURITY.md.
#
# Safe to hand-edit; re-running `plan` reads it back as defaults and shows a
# diff before replacing anything.

EOF
printf '# ---------------------------------------------------------------- the hub\n'
printf 'HUB_USER="%s"\n'    "$HUB_USER"
printf 'HUB_HOST="%s"\n'    "$HUB_HOST"
printf 'HUB_KEY="%s"\n'     "$HUB_KEY"
printf '# Hub SSH port. status and doctor read it; edit if the hub is not on 22.\n'
printf 'HUB_PORT=%s\n\n'      "${HUB_PORT:-22}"
printf '# Snapshot root. Must be on the backup drive, never the hub system disk.\n'
printf 'BACKUP_ROOT="%s"\n\n' "$BACKUP_ROOT"
printf '# Volumes the tooling may mount or repair. Anything not listed is refused.\n'
printf '# NEWLINE-separated, not space-separated: a macOS volume name commonly\n'
printf '# contains spaces and a space-separated list cannot hold one.\n'
printf 'MANAGED_VOLUMES="%s"\n\n' "$MANAGED_VOLUMES"
printf '# ------------------------------------------------------------- hosts\n'
printf 'BACKUP_HOSTS="%s"\n' "$NEW_HOSTS"
printf '# Hosts that push to the hub; they have no hub-side scheduler.\n'
printf 'PUSH_HOSTS="%s"\n\n' "$NEW_PUSH"
printf '# Hours before the watchdog calls a backup stale. Derived from each\n'
printf '# schedule with 25%% slack, so one late run is not an alarm.\n'
printf 'FRESHNESS="%s"\n\n' "$NEW_FRESH"
printf '# ------------------------------------------------------------- scheduling\n'
printf 'PULL_LABEL_PREFIX="%s"\n' "$PULL_LABEL_PREFIX"
printf 'REMOTE_CMD="%s"\n\n' "$REMOTE_CMD"
printf '# ------------------------------------------------------------- tuning\n'
printf 'BWLIMIT=%s\n' "$BWLIMIT"
printf 'KEEP_HOURLY=%s\n'  "$KEEP_HOURLY"
printf 'KEEP_DAILY=%s\n'   "$KEEP_DAILY"
printf 'KEEP_WEEKLY=%s\n'  "$KEEP_WEEKLY"
printf 'KEEP_MONTHLY=%s\n\n' "$KEEP_MONTHLY"
printf '# ------------------------------------------- optional: Time Machine view\n'
printf 'ADVERTISER_PATTERN="%s"\n' "$ADVERTISER_PATTERN"
printf 'ADVERTISER_LABEL="%s"\n\n' "$ADVERTISER_LABEL"
printf '# ------------------------------------------- optional: watchdog view\n'
printf 'WATCHDOG_HOST="%s"\n' "$WATCHDOG_HOST"
printf 'WATCHDOG_KEY="%s"\n'  "$WATCHDOG_KEY"
} >> "$HUB_TMP"

say
write_conf "$HUB_CONF" "$HUB_TMP"

for t in $NEW_HOSTS; do
  # shellcheck disable=SC1090
  . "$TMP/h.$t"
  ht="$TMP/host.$t"
  write_host_conf "$t" "$TMP" "$ht"
  write_conf "$OUT/hosts/$t.conf" "$ht"
done

cat <<EOF

${D}Nothing has been provisioned. Review the files above, then:

  snapfabric provision   install keys, agents and schedules from this plan
  snapfabric verify      prove a restore works once backups have run${N}
EOF
