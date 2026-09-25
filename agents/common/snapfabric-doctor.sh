#!/bin/bash
# snapfabric doctor — external health check and self-repair for the hub.
#
# Invoked as `snapfabric doctor`. Runs on a SECOND machine, deliberately: a
# watchdog on the host it watches cannot report that host being down. Run it
# from any machine that can reach the hub -- a backed-up node is the obvious
# choice, since it is already there and already has the fabric's interest in
# the hub being up.
#
# Nothing here is platform-specific; it needs bash and ssh. It lived under
# agents/linux/ only because the first fabric ran it from a Linux box.
#
# Talks to the hub only through the `snapfabric-remote` verb API, which is
# installed there as a forced SSH command. This watchdog therefore CANNOT run
# arbitrary commands on the hub even if this machine is compromised — see
# docs/SECURITY.md. Every argument it sends is also validated hub-side against
# an allowlist.
#
# Repairs: remount volumes, fix wrong-path mounts, restart schedulers and the
# Time Machine advertiser, trigger stale backups. It never deletes backup data.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# epoch_of lives here, shared with status and the engine. Sourced rather than
# copied: this script previously carried its own GNU-only fourth copy, which
# silently skipped every host on a macOS watchdog.
# shellcheck source=lib-validate.sh
. "$HERE/lib-validate.sh" || { echo "doctor: cannot load lib-validate.sh" >&2; exit 1; }

case "${1:-}" in
  -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
esac

# Scratch files. These were predictable /tmp paths built from $$: guessable, and
# /tmp is world-writable, so a pre-created symlink redirects the write. The sticky bit
# does not prevent that. Every other script in this repo already used mktemp -d,
# and this is the one the docs tell you to run from cron every 15 minutes.
SFTMP=$(mktemp -d) || { echo "doctor: cannot create a temp directory" >&2; exit 1; }
chmod 700 "$SFTMP"
trap 'rm -rf "$SFTMP"' EXIT

CONF="${SNAPFABRIC_CONF:-$HOME/.config/snapfabric/snapfabric.conf}"
[ -r "$CONF" ] || { echo "snapfabric doctor: no config at $CONF" >&2; exit 2; }
# shellcheck disable=SC1090
. "$CONF"

HUB="${HUB_USER:?config must set HUB_USER}@${HUB_HOST:?config must set HUB_HOST}"
KEY="${HUB_KEY:-$HOME/.ssh/snapfabric_watchdog}"
# StrictHostKeyChecking=accept-new is required: without it a fresh account has
# no known_hosts entry and the watchdog reports "hub unreachable" for a hub that
# is perfectly healthy.
# -n is load-bearing, not tidiness: ssh reads stdin, and every repair call below
# sits inside a `while read` loop. Without it, one triggered repair consumes the
# rest of the loop's input and every remaining host is silently skipped -- the
# hosts simply vanish from the report, with no error anywhere.
# -p, because an estate can put its hub on a non-standard port (constraint 24).
SSH="ssh -n -i $KEY -p ${HUB_PORT:-22} -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$HOME/.ssh/known_hosts"

# Runs as the owning user, never root: $HOME must resolve to somewhere the key
# and state actually live.
LOG="$HOME/backup-watchdog.log"
STATE="$HOME/.backup-watchdog"
mkdir -p "$STATE" 2>/dev/null

# Freshness limits come from FRESHNESS in the config, formatted "host:hours".
# A case statement would hardcode host names; bash 3.2 has no associative arrays.
limit_for(){
  local want="$1" pair
  for pair in ${FRESHNESS:-}; do
    case "$pair" in "$want":*) echo "${pair#*:}"; return ;; esac
  done
  echo "${DEFAULT_FRESHNESS_HOURS:-30}"
}

# Hosts that push to the hub themselves cannot be triggered by the hub. List
# them in PUSH_HOSTS; everything else is pulled and is triggerable.
is_push_host(){
  local want="$1" h
  for h in ${PUSH_HOSTS:-}; do [ "$h" = "$want" ] && return 0; done
  return 1
}

# --- repair backoff -----------------------------------------------------------
# Retrying the same failing repair on a fixed interval is not self-healing, it
# is a loop. In testing this restarted a backup job every 15 minutes
# for three hours -- twelve consecutive attempts, every one failing against a
# full volume -- and the retries actively HID the outage: the report kept
# showing a repair being attempted, so it looked handled.
#
# After MAX_REPAIR_ATTEMPTS consecutive failures for one target, stop and
# escalate. A repair that has failed twelve times will not work on the
# thirteenth; what is needed then is a person, and saying so is the repair.
MAX_REPAIR_ATTEMPTS="${MAX_REPAIR_ATTEMPTS:-3}"
_fail_file(){ echo "$STATE/fail.$(echo "$1" | tr -c 'A-Za-z0-9._-' '_')"; }
fail_count(){ cat "$(_fail_file "$1")" 2>/dev/null || echo 0; }
fail_bump(){ echo $(( $(fail_count "$1") + 1 )) > "$(_fail_file "$1")"; }
fail_reset(){ rm -f "$(_fail_file "$1")"; }
should_attempt(){ [ "$(fail_count "$1")" -lt "$MAX_REPAIR_ATTEMPTS" ]; }

ts(){ date '+%Y-%m-%d %H:%M:%S'; }
log(){ echo "[$(ts)] $*" >> "$LOG"; }
alerts=""; repairs=""
add_alert(){ alerts="${alerts}${alerts:+$'\n'}$1"; }
add_repair(){ repairs="${repairs}${repairs:+$'\n'}$1"; }

log "=== watchdog start ==="

# ---------------------------------------------------------------- reachability
if ! $SSH "$HUB" ping 2>/dev/null | grep -q '^ok'; then
  log "CRITICAL: hub unreachable"
  { echo "checked: $(ts)"; echo "status: CRITICAL"; echo "ALERT hub unreachable"; } > "$STATE/status"
  exit 1
fi

SNAP=$($SSH "$HUB" status 2>/dev/null)
[ -n "$SNAP" ] || { log "CRITICAL: status returned nothing"; \
  { echo "checked: $(ts)"; echo "status: CRITICAL"; echo "ALERT hub status unavailable"; } > "$STATE/status"; exit 1; }

# ---------------------------------------------------------------- volumes
# Checks the volume is mounted AT THE EXPECTED PATH, not merely mounted. After a
# USB re-enumeration macOS can mount it as "/Volumes/Backups 1": perfectly
# healthy, but every script pointing at the real path fails. Asking only
# "is it mounted?" missed this for a full day.
echo "$SNAP" | grep '^VOL|' | while IFS='|' read -r _ v name pct wrong; do
  echo "VOLCHECK|$v|$name|$pct|$wrong"
done > "$SFTMP/sfvol"
while IFS='|' read -r _ v name pct wrong; do
  if [ -n "$wrong" ] || [ "$name" != "$v" ]; then
    if [ -n "$wrong" ]; then add_alert "volume $v mounted at WRONG PATH: $wrong"
    else add_alert "volume $v NOT MOUNTED"; fi
    if $SSH "$HUB" "fix-mountpoint $v" 2>/dev/null | grep -q '^repaired'; then
      add_repair "remounted $v at the correct path"
    else
      add_alert "volume $v repair FAILED — needs manual attention"
    fi
    continue
  fi
  log "volume $v ${pct}% full"
  # Per-volume fill matters independently of container free space: a volume can
  # sit at 98% of its own quota while the container still reports 33% free.
  if   [ "${pct:-0}" -ge 95 ] 2>/dev/null; then add_alert "CRITICAL volume $v is ${pct}% full"
  elif [ "${pct:-0}" -ge 85 ] 2>/dev/null; then add_alert "volume $v is ${pct}% full"
  fi
done < "$SFTMP/sfvol"
rm -f "$SFTMP/sfvol"

# ---------------------------------------------------------------- services
# dom is read to absorb the SVC domain field; without it $st would swallow it.
# shellcheck disable=SC2034
echo "$SNAP" | grep '^SVC|' | while IFS='|' read -r _ l st dom; do echo "$l|$st"; done > "$SFTMP/sfsvc"
while IFS='|' read -r l st; do
  [ "$st" = "loaded" ] && { fail_reset "svc.$l"; continue; }
  add_alert "service $l NOT LOADED"
  if ! should_attempt "svc.$l"; then
    add_alert "ESCALATE $l: $(fail_count "svc.$l") failed repair attempts, not retrying — needs a human"
    continue
  fi
  if $SSH "$HUB" "restart-service $l" 2>/dev/null | grep -q '^restarted'; then
    add_repair "restarted $l"; fail_reset "svc.$l"
  else
    fail_bump "svc.$l"
    add_alert "restart of $l FAILED (attempt $(fail_count "svc.$l")/$MAX_REPAIR_ATTEMPTS)"
  fi
done < "$SFTMP/sfsvc"
rm -f "$SFTMP/sfsvc"

# The Bonjour advertiser is the most fragile piece: without _adisk._tcp the
# a client's Time Machine creates a sparsebundle and then rolls it back.
if [ -n "${ADVERTISER_LABEL:-}" ] && echo "$SNAP" | grep -q '^ADV|down'; then
  add_alert "Time Machine advertiser DOWN"
  if $SSH "$HUB" "restart-service ${ADVERTISER_LABEL}" 2>/dev/null | grep -q '^restarted'; then
    add_repair "restarted TM advertiser"
  else
    add_alert "TM advertiser repair FAILED"
  fi
fi

# ---------------------------------------------------------------- staleness
now=$(date +%s)
# Five fields: the hub reports the newest DIRECTORY and, separately, the target
# of "latest", which only advances when a run COMPLETES. Measuring the newest
# directory counts attempts as successes -- see constraint 28.
echo "$SNAP" | grep '^SNAP|' | while IFS='|' read -r _ h n newest good; do echo "$h|$n|$newest|$good"; done > "$SFTMP/sfsnap"
while IFS='|' read -r h n newest good; do
  ref="${good:-$newest}"
  if [ "${n:-0}" -eq 0 ] || [ -z "$newest" ]; then
    add_alert "$h has NO snapshots"
    # A host with zero snapshots previously only alerted and never self-repaired,
    # so it stayed broken until its own schedule happened to fire.
    # Bounded like the stale path below: a first seed can run for days, and
    # re-triggering it every 15 minutes neither helps nor says anything new.
    if ! is_push_host "$h"; then
      if should_attempt "stale.$h"; then
        fail_bump "stale.$h"
        $SSH "$HUB" "run-backup $h" >/dev/null 2>&1 \
          && add_repair "triggered $h backup (attempt $(fail_count "stale.$h")/$MAX_REPAIR_ATTEMPTS)"
      else
        add_alert "ESCALATE $h: no snapshots after $(fail_count "stale.$h") triggers — a first seed may be running, otherwise it needs a human"
      fi
    fi
    continue
  fi
  e=$(epoch_of "$ref")
  [ "$e" -eq 0 ] && { log "WARN cannot parse timestamp for $h ($ref)"; continue; }
  age=$(( (now - e) / 3600 )); lim=$(limit_for "$h")
  log "$h lastgood=$ref newest=$newest age=${age}h limit=${lim}h"
  if [ "$age" -gt "$lim" ]; then
    add_alert "$h backup STALE (${age}h > ${lim}h)"
    # A push host runs its own agent; the hub has no job to kickstart for it.
    if ! is_push_host "$h"; then
      if should_attempt "stale.$h"; then
        fail_bump "stale.$h"
        $SSH "$HUB" "run-backup $h" >/dev/null 2>&1 \
          && add_repair "triggered $h backup (attempt $(fail_count "stale.$h")/$MAX_REPAIR_ATTEMPTS)"
      else
        add_alert "ESCALATE $h: still stale after $(fail_count "stale.$h") triggers — a long seed may be in progress, otherwise it needs a human"
      fi
    fi
  else
    fail_reset "stale.$h"
  fi
done < "$SFTMP/sfsnap"
rm -f "$SFTMP/sfsnap"

# ---------------------------------------------------------------- capacity
free=$(echo "$SNAP" | grep '^FREE|' | cut -d'|' -f2)
if [ -n "$free" ]; then
  fi_=${free%%.*}
  log "container free: ${free}%"
  if   [ "${fi_:-100}" -lt 8 ]  2>/dev/null; then add_alert "CRITICAL container only ${free}% free"
  elif [ "${fi_:-100}" -lt 15 ] 2>/dev/null; then add_alert "container only ${free}% free"
  fi
fi

# ---------------------------------------------------------------- report
# Messages are newline-separated and contain spaces. `printf '%s\n' $var`
# word-splits them into one line per WORD -- "restarted TM advertiser" became
# three separate REPAIRED lines. Iterate line-by-line instead.
{
  echo "checked: $(ts)"
  if [ -z "$alerts" ]; then
    echo "status: OK"
  else
    echo "status: ATTENTION"
    printf '%s\n' "$alerts" | while IFS= read -r a; do [ -n "$a" ] && echo "ALERT $a"; done
  fi
  [ -n "$repairs" ] && printf '%s\n' "$repairs" | while IFS= read -r r; do [ -n "$r" ] && echo "REPAIRED $r"; done
} > "$STATE/status"

[ -n "$alerts" ]  && printf '%s\n' "$alerts"  | while IFS= read -r a; do [ -n "$a" ] && log "ALERT $a"; done
[ -n "$repairs" ] && printf '%s\n' "$repairs" | while IFS= read -r r; do [ -n "$r" ] && log "REPAIR $r"; done
[ -z "$alerts" ] && log "all clear"
log "=== watchdog end ==="
