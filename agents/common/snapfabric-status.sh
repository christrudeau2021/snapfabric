#!/bin/bash
# snapfabric status — one-screen health report for the backup fabric.
#
#   usage: snapfabric-status.sh [--plain]
#
# Reads everything from snapfabric.conf and a single `snapfabric-remote status`
# call on the hub. Read-only: it never changes anything. `snapfabric doctor`
# (the watchdog) is the one that repairs.
#
# Exit code is the verdict, so it can gate other automation:
#   0 all green   1 warnings   2 needs attention

set -uo pipefail

# --help must be handled BEFORE the config is read and the hub is contacted.
# Without it, `snapfabric help status` ran a full live query against the real
# hub -- which also meant the test asserting "every advertised command has an
# implementation" was passing by making a network call to production.
case "${1:-}" in
  -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
esac

PLAIN=0; [ "${1:-}" = "--plain" ] && PLAIN=1

CONF="${SNAPFABRIC_CONF:-$HOME/.config/snapfabric/snapfabric.conf}"
[ -r "$CONF" ] || { echo "snapfabric: no config at $CONF" >&2; exit 2; }
# shellcheck disable=SC1090
. "$CONF"

HUB="${HUB_USER:?config must set HUB_USER}@${HUB_HOST:?config must set HUB_HOST}"
KEY="${HUB_KEY:-$HOME/.ssh/snapfabric_hub}"
# IdentitiesOnly: authenticate with HUB_KEY and nothing else. Without it ssh
# also offers agent and default identities, so a key that is NOT the restricted
# hub key can answer -- bypassing the forced command, and with it the pinned
# config path. The restriction then stops being exercised at all.
# -p, because an estate can put its hub on a non-standard port. Hardcoding 22
# is constraint 24, which the engine was fixed for and these two were not.
SSH="ssh -i $KEY -o IdentitiesOnly=yes -p ${HUB_PORT:-22} -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new"
# Name the program explicitly. A forced-command key ignores this and strips it;
# an unrestricted key needs it, or ssh runs the system `ping` instead.
REMOTE="${REMOTE_CMD:-~/bin/snapfabric-remote}"

G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'
{ [ -t 1 ] && [ "$PLAIN" -eq 0 ]; } || { G=""; Y=""; R=""; B=""; D=""; N=""; }
OK="${G}●${N}"; WARN="${Y}●${N}"; BAD="${R}●${N}"

worst=0
bump(){ [ "$1" -gt "$worst" ] && worst=$1; return 0; }
hdr(){ printf "\n${B}%s${N}\n" "$1"; }
row(){ printf "  %s %-12s %s\n" "$1" "$2" "$3"; }

# FRESHNESS is "host:hours" pairs; bash 3.2 has no associative arrays.
limit_for(){
  local want="$1" pair
  for pair in ${FRESHNESS:-}; do
    case "$pair" in "$want":*) echo "${pair#*:}"; return ;; esac
  done
  echo "${DEFAULT_FRESHNESS_HOURS:-30}"
}
is_push(){ local h; for h in ${PUSH_HOSTS:-}; do [ "$h" = "$1" ] && return 0; done; return 1; }

epoch_of(){
  local n="$1"
  date -j -f "%Y-%m-%d_%H%M%S" "$n" +%s 2>/dev/null && return 0
  date -d "$(echo "$n" | sed 's/_/ /; s/\(..\)\(..\)\(..\)$/\1:\2:\3/')" +%s 2>/dev/null && return 0
  echo 0
}
ago(){
  local s=$(( $(date +%s) - $1 ))
  if   [ "$s" -lt 3600 ];  then echo "$((s/60))m ago"
  elif [ "$s" -lt 86400 ]; then echo "$((s/3600))h ago"
  else echo "$((s/86400))d ago"; fi
}

printf "${B}BACKUP STATUS${N}  ${D}%s  ·  hub %s${N}\n" "$(date '+%Y-%m-%d %H:%M')" "$HUB_HOST"

# ---------------------------------------------------------------- hub
if ! $SSH "$HUB" "$REMOTE ping" 2>/dev/null | grep -q '^ok'; then
  hdr "HUB"; row "$BAD" "$HUB_HOST" "UNREACHABLE — cannot query the backup drive"
  printf "\n  ${R}${B}VERDICT: CRITICAL${N}\n\n"; exit 2
fi
SNAP=$($SSH "$HUB" "$REMOTE status" 2>/dev/null)
[ -n "$SNAP" ] || { hdr "HUB"; row "$BAD" "$HUB_HOST" "status returned nothing"; \
  printf "\n  ${R}${B}VERDICT: CRITICAL${N}\n\n"; exit 2; }

# ---------------------------------------------------------------- hosts
hdr "HOSTS"
# Piping into `while` would run the loop in a subshell and lose `worst`.
while IFS='|' read -r tag h n newest good; do
  [ "$tag" = "SNAP" ] || continue
  tail=""; is_push "$h" && tail=" ${D}(push)${N}"
  if [ "${n:-0}" -eq 0 ] || [ -z "$newest" ]; then
    row "$BAD" "$h" "NO SNAPSHOTS${tail}"; bump 2; continue
  fi
  # Measure from the last COMPLETED snapshot. Using the newest directory name
  # reported a host as 4 hours fresh whose last good backup was 10 days old --
  # the newer directory was an in-progress pull, and before it three failures.
  # A dashboard that counts attempts instead of successes is worse than none.
  ref="$good"
  if [ -z "$ref" ]; then
    ref="$newest"; tail="$tail ${Y}(no 'latest' — never completed)${N}"
  elif [ "$newest" != "$good" ]; then
    tail="$tail ${D}(+1 in progress/incomplete)${N}"
  fi
  e=$(epoch_of "$ref")
  if [ "$e" -eq 0 ]; then row "$WARN" "$h" "$n snapshots · unparseable timestamp"; bump 1; continue; fi
  age=$(( ($(date +%s) - e) / 3600 )); lim=$(limit_for "$h")
  if [ "$age" -le "$lim" ]; then s="$OK"; else s="$BAD"; bump 2; fi
  row "$s" "$h" "$n snapshots · last good $(ago "$e")${tail}"
done <<< "$SNAP"

# ---------------------------------------------------------------- storage
hdr "STORAGE"
while IFS='|' read -r tag v name pct wrong; do
  [ "$tag" = "VOL" ] || continue
  if [ -n "$wrong" ]; then
    # Healthy volume, wrong mount point -- every script pointing at the real
    # path fails. A plain "is it mounted?" check misses this entirely.
    row "$BAD" "$v" "WRONG MOUNT PATH: $wrong"; bump 2; continue
  fi
  if [ -z "$pct" ] || [ "$name" != "$v" ]; then row "$BAD" "$v" "NOT MOUNTED"; bump 2; continue; fi
  if   [ "$pct" -ge 95 ]; then s="$BAD"; bump 2
  elif [ "$pct" -ge 85 ]; then s="$WARN"; bump 1
  else s="$OK"; fi
  row "$s" "$v" "${pct}% used"
done <<< "$SNAP"

free=$(printf '%s\n' "$SNAP" | grep '^FREE|' | cut -d'|' -f2)
if [ -n "$free" ]; then
  # Container free space and per-volume fill are independent: a volume can sit at
  # 98% of its own quota while the container still reports plenty free.
  fi_=${free%%.*}
  if   [ "${fi_:-100}" -lt 8 ];  then s="$BAD"; bump 2
  elif [ "${fi_:-100}" -lt 15 ]; then s="$WARN"; bump 1
  else s="$OK"; fi
  row "$s" "container" "${free}% free"
fi

# ---------------------------------------------------------------- services
hdr "SERVICES"
nsvc=0; nbad=0
# Four fields, not three: the verb API reports which launchd domain holds the
# job. Reading three would absorb "loaded|gui/501" into $st and report every
# healthy scheduler as NOT LOADED.
# shellcheck disable=SC2034  # dom absorbs the domain field so $st stays clean
while IFS='|' read -r tag l st dom; do
  [ "$tag" = "SVC" ] || continue
  nsvc=$((nsvc+1)); [ "$st" = "loaded" ] || { nbad=$((nbad+1)); row "$BAD" "scheduler" "$l NOT LOADED"; bump 2; }
done <<< "$SNAP"
[ "$nbad" -eq 0 ] && row "$OK" "schedulers" "$nsvc loaded"

adv=$(printf '%s\n' "$SNAP" | grep '^ADV|' | cut -d'|' -f2)
case "$adv" in
  up)   row "$OK"   "TM advert" "broadcasting" ;;
  down) row "$BAD"  "TM advert" "DOWN — network Time Machine will fail"; bump 2 ;;
  *)    [ -n "${ADVERTISER_LABEL:-}" ] && { row "$WARN" "TM advert" "unknown"; bump 1; } ;;
esac

# Optional: the watchdog's own view, from wherever it runs.
if [ -n "${WATCHDOG_HOST:-}" ]; then
  # WATCHDOG_HOST may be an ssh alias (which supplies its own IdentityFile) or a
  # bare user@host, which needs WATCHDOG_KEY -- otherwise this reports "no status
  # file" for a watchdog that is running perfectly well.
  _wk=""; [ -n "${WATCHDOG_KEY:-}" ] && _wk="-i ${WATCHDOG_KEY}"
  # shellcheck disable=SC2086
  wd=$(ssh $_wk -o BatchMode=yes -o ConnectTimeout=10 "$WATCHDOG_HOST" \
        "cat ${WATCHDOG_STATUS:-\$HOME/.backup-watchdog/status} 2>/dev/null" 2>/dev/null)
  if [ -z "$wd" ]; then row "$WARN" "watchdog" "no status file"; bump 1
  elif printf '%s\n' "$wd" | grep -q "status: OK"; then
    row "$OK" "watchdog" "OK · $(printf '%s\n' "$wd" | grep '^checked' | cut -d' ' -f2-)"
  else
    row "$WARN" "watchdog" "$(printf '%s\n' "$wd" | grep -m1 '^ALERT' | sed 's/^ALERT //')"; bump 1
  fi
fi

case $worst in
  0) printf "\n  ${G}${B}VERDICT: ALL GREEN${N}\n\n" ;;
  1) printf "\n  ${Y}${B}VERDICT: WARNINGS${N} ${D}(nothing broken, worth a look)${N}\n\n" ;;
  2) printf "\n  ${R}${B}VERDICT: NEEDS ATTENTION${N}\n\n" ;;
esac
exit $worst
