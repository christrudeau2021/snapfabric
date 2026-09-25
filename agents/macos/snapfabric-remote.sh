#!/bin/bash
# snapfabric-remote — forced-command dispatcher for the watchdog key.
#
# Installed on the HUB as the forced command for the watchdog's SSH key:
#   command="<hubhome>/bin/snapfabric-remote",no-agent-forwarding,
#   no-port-forwarding,no-pty,no-user-rc ssh-ed25519 …
#
# WHY A VERB API RATHER THAN A COMMAND FILTER
# The watchdog needs launchctl, diskutil and therefore sudo. Granting it a shell
# means compromising the watchdog host yields ROOT on the hub — the machine
# holding every backup. Filtering arbitrary shell with patterns is fragile: too
# loose buys nothing, too tight breaks the watchdog silently.
#
# Instead the caller may only invoke a fixed set of verbs, and every argument is
# validated against an allowlist. There is no path from here to an arbitrary
# command. Read `case` below — that is the entire attack surface.

set -uo pipefail

# --- allowlists -------------------------------------------------------------
# Derived entirely from the operator's config; nothing is baked in. The config
# lives beside this script on the hub and must be mode 0600.
CONF="${SNAPFABRIC_CONF:-$HOME/.config/snapfabric/snapfabric.conf}"
[ -r "$CONF" ] || { echo "snapfabric-remote: no config at $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

BACKUP_ROOT="${BACKUP_ROOT:?config must set BACKUP_ROOT}"
ALLOWED_VOLUMES="${MANAGED_VOLUMES:?config must set MANAGED_VOLUMES}"
ALLOWED_HOSTS="${BACKUP_HOSTS:?config must set BACKUP_HOSTS}"
ADVERTISER_PATTERN="${ADVERTISER_PATTERN:-}"

# Per-host scheduler labels are PULL_LABEL_PREFIX + "." + host, so adding a host
# to BACKUP_HOSTS cannot silently leave its scheduler unmanageable. The
# advertiser label is separate because it is not per-host and rarely shares the
# same naming convention as the pull jobs.
PULL_LABEL_PREFIX="${PULL_LABEL_PREFIX:?config must set PULL_LABEL_PREFIX}"
ADVERTISER_LABEL="${ADVERTISER_LABEL:-}"
# PUSH hosts run their own agent and have NO hub-side scheduler, so they must be
# excluded here. Including them made `status` report a permanently "missing"
# service and the watchdog would try to repair something that should not exist.
PUSH_HOSTS="${PUSH_HOSTS:-}"
_is_push(){ for _p in $PUSH_HOSTS; do [ "$_p" = "$1" ] && return 0; done; return 1; }
ALLOWED_LABELS=""
for _h in $ALLOWED_HOSTS; do
  _is_push "$_h" && continue
  ALLOWED_LABELS="$ALLOWED_LABELS ${PULL_LABEL_PREFIX}.${_h}"
done
[ -n "$ADVERTISER_LABEL" ] && ALLOWED_LABELS="$ALLOWED_LABELS $ADVERTISER_LABEL"

deny(){ echo "snapfabric-remote: refused: $*" >&2; exit 1; }

# Which launchd domain a scheduler lives in.
#
# provision installs a USER LaunchAgent (~/Library/LaunchAgents, bootstrapped
# into gui/<uid>), because the macOS hub reaches the backup drive through
# `ssh localhost` and that design assumes a user agent. This script asked
# launchd about `system/<label>` instead. The two never agreed, so every
# scheduler reported `missing` -- a permanent NEEDS ATTENTION on a healthy hub --
# and every repair and trigger targeted a domain the job was not in and could
# not succeed. The watchdog then retried a repair that could never work.
#
# Ask about both, user domain first, and report the one that answers.
sf_domain(){ # sf_domain <label> -> prints the domain holding it, or nothing
  local l="$1" gui
  gui="gui/$(id -u)"
  /bin/launchctl print "$gui/$l" >/dev/null 2>&1 && { printf '%s' "$gui"; return 0; }
  /bin/launchctl print "system/$l" >/dev/null 2>&1 && { printf '%s' "system"; return 0; }
  return 1
}

# The plist backing a label, whichever domain installed it.
sf_plist(){ # sf_plist <label>
  local l="$1"
  for c in "$HOME/Library/LaunchAgents/$l.plist" "/Library/LaunchDaemons/$l.plist"; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

in_list(){ # in_list <needle> <space-separated haystack>
  local n="$1" h="$2" i
  for i in $h; do [ "$i" = "$n" ] && return 0; done
  return 1
}

# Arguments must be plain tokens. Rejecting shell metacharacters outright means
# even a mistake in a downstream quote cannot become command execution.
safe_token(){
  case "$1" in
    *[\;\&\|\`\$\(\)\<\>\'\"*?[]*|*' '*|"") return 1 ;;
    *) return 0 ;;
  esac
}

# Same rejected charset, spaces permitted. Verb arguments may legitimately be a
# macOS volume name, and those contain spaces more often than not.
safe_arg(){
  case "$1" in
    *[\;\&\|\`\$\(\)\<\>\'\"*?[]*|"") return 1 ;;
    *) return 0 ;;
  esac
}

# Volume names are NEWLINE-separated in config for exactly the reason SOURCES
# is (constraint 18): a space-separated list cannot hold "My Backup Drive".
in_list_nl(){ # in_list_nl <needle> <newline-separated haystack>
  local n="$1" h="$2" i OLD="$IFS"
  IFS='
'
  for i in $h; do
    IFS="$OLD"
    [ "$i" = "$n" ] && return 0
    IFS='
'
  done
  IFS="$OLD"; return 1
}

# The key is a forced command, so the real request arrives in SSH_ORIGINAL_COMMAND.
# Fall back to positional args so the script can be tested directly.
REQ="${SSH_ORIGINAL_COMMAND:-$*}"
set -- $REQ
# Callers reach this two ways and both must work:
#   - via a forced-command key, where the verb arrives bare ("status")
#   - via an unrestricted key, which must name the program
#     ("snapfabric-remote status") or ssh would run /sbin/ping etc. instead
# So drop a leading program name if present.
case "${1:-}" in
  snapfabric-remote|*/snapfabric-remote) shift ;;
esac
VERB="${1:-}"; shift 2>/dev/null || true

# Every verb takes zero or one argument, so the remaining words are rejoined
# into ONE argument. Splitting on spaces made a volume named "Backups of
# Drive" arrive as three arguments and be refused as unknown.
ARG="$*"
[ -n "$ARG" ] && { safe_arg "$ARG" || deny "unsafe argument"; }

case "$VERB" in

  # ---- read-only -----------------------------------------------------------
  ping)
    echo "ok $(hostname -s)"
    ;;

  status)
    # Everything the watchdog needs, in one round trip.
    OLDIFS="$IFS"; IFS='
'
    for v in $ALLOWED_VOLUMES; do
      IFS="$OLDIFS"
      mp="/Volumes/$v"
      name=$(diskutil info "$mp" 2>/dev/null | awk -F': *' '/Volume Name/{gsub(/^ +| +$/,"",$2); print $2; exit}')
      pct=$(df -k "$mp" 2>/dev/null | awk 'NR==2{gsub("%","");print $5}')
      wrong=$(ls -d "/Volumes/${v} "[0-9]* 2>/dev/null | head -1)
      echo "VOL|$v|${name:-}|${pct:-}|${wrong:-}"
      IFS='
'
    done
    IFS="$OLDIFS"
    for h in $ALLOWED_HOSTS; do
      # shellcheck disable=SC2010  # snapshot dirs are strictly dated; the grep enforces it
      n=$(ls -1 "$BACKUP_ROOT/$h" 2>/dev/null | grep -c '^[0-9]')
      # shellcheck disable=SC2010
      newest=$(ls -1 "$BACKUP_ROOT/$h" 2>/dev/null | grep '^[0-9]' | sort | tail -1)
      # "latest" only advances on a COMPLETED run, so it -- not the newest
      # directory -- is what freshness must be measured from. A directory newer
      # than this is a run in progress or the wreck of one that failed.
      good=$(readlink "$BACKUP_ROOT/$h/latest" 2>/dev/null | sed 's|.*/||')
      echo "SNAP|$h|$n|${newest:-}|${good:-}"
    done
    for l in $ALLOWED_LABELS; do
      if d=$(sf_domain "$l"); then echo "SVC|$l|loaded|$d"; else echo "SVC|$l|missing"; fi
    done
    if [ -n "$ADVERTISER_PATTERN" ]; then
      pgrep -f "$ADVERTISER_PATTERN" >/dev/null 2>&1 && echo "ADV|up" || echo "ADV|down"
    else
      echo "ADV|n/a"
    fi
    cont=$(diskutil info "$BACKUP_ROOT" 2>/dev/null | grep 'APFS Container:' | tr -d ' ' | cut -d: -f2)
    free=$(diskutil apfs list "$cont" 2>/dev/null | grep 'Capacity Not Allocated' | grep -oE '[0-9.]+% free' | cut -d% -f1)
    echo "FREE|${free:-}"
    ;;

  # ---- repair --------------------------------------------------------------
  mount)
    v="$ARG"; in_list_nl "$v" "$ALLOWED_VOLUMES" || deny "volume not allowed: $v"
    /usr/sbin/diskutil mount "$v" >/dev/null 2>&1 && echo "mounted $v" || deny "mount failed: $v"
    ;;

  fix-mountpoint)
    # Repairs the "/Volumes/Backups 1" case: unmount the wrong path, move the
    # squatting directory aside, remount by volume name, then re-verify.
    v="$ARG"; in_list_nl "$v" "$ALLOWED_VOLUMES" || deny "volume not allowed: $v"
    mp="/Volumes/$v"
    wrong=$(ls -d "/Volumes/${v} "[0-9]* 2>/dev/null | head -1)
    [ -n "$wrong" ] && /usr/sbin/diskutil unmount "$wrong" >/dev/null 2>&1
    # Never rm -rf a /Volumes path in automation; move it instead.
    if ! /usr/sbin/diskutil info "$mp" >/dev/null 2>&1 && [ -e "$mp" ]; then
      /bin/rmdir "$mp" 2>/dev/null || /bin/mv "$mp" "${mp}.stale-$(date +%Y%m%d-%H%M%S)" 2>/dev/null
    fi
    /usr/sbin/diskutil mount "$v" >/dev/null 2>&1
    sleep 2
    got=$(/usr/sbin/diskutil info "$mp" 2>/dev/null | awk -F': *' '/Volume Name/{gsub(/^ +| +$/,"",$2); print $2; exit}')
    [ "$got" = "$v" ] && echo "repaired $v at $mp" || deny "repair failed for $v"
    ;;

  restart-service)
    l="$ARG"; in_list "$l" "$ALLOWED_LABELS" || deny "label not allowed: $l"
    # kickstart only works on an already-loaded job; bootstrap covers the case
    # where it was booted out entirely. Then verify it actually came back.
    # A user agent is restarted WITHOUT sudo; only a system daemon needs it.
    # Using sudo for both meant a user agent could not be restarted at all on a
    # hub whose account has no passwordless sudo -- and asking for one is a
    # privilege this key should not need.
    dom=$(sf_domain "$l") || dom=""
    plist=$(sf_plist "$l") || plist=""
    case "$dom" in
      system) /usr/bin/sudo /bin/launchctl kickstart -k "system/$l" >/dev/null 2>&1 ;;
      "")     : ;;
      *)      /bin/launchctl kickstart -k "$dom/$l" >/dev/null 2>&1 ;;
    esac
    if [ -z "$dom" ] && [ -n "$plist" ]; then
      case "$plist" in
        "$HOME"/*) /bin/launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1 ;;
        *)         /usr/bin/sudo /bin/launchctl bootstrap system "$plist" >/dev/null 2>&1 ;;
      esac
    fi
    sleep 2
    sf_domain "$l" >/dev/null 2>&1 && echo "restarted $l" || deny "restart failed: $l"
    ;;

  run-backup)
    h="$ARG"; in_list "$h" "$ALLOWED_HOSTS" || deny "host not allowed: $h"
    l="${PULL_LABEL_PREFIX}.${h}"
    in_list "$l" "$ALLOWED_LABELS" || deny "no scheduler for host: $h"
    dom=$(sf_domain "$l") || deny "no loaded scheduler for host: $h"
    case "$dom" in
      system) /usr/bin/sudo /bin/launchctl kickstart -k "system/$l" >/dev/null 2>&1 ;;
      *)      /bin/launchctl kickstart -k "$dom/$l" >/dev/null 2>&1 ;;
    esac \
      && echo "triggered $h" || deny "trigger failed: $h"
    ;;

  *)
    deny "unknown verb: ${VERB:-<none>} (allowed: ping status mount fix-mountpoint restart-service run-backup)"
    ;;
esac
