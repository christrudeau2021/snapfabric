#!/bin/bash
# snapfabric add-node — onboard ONE host into a fabric that already exists.
#
#   usage: snapfabric-addnode.sh [--conf DIR] [--replace] [--no-provision] [--yes] [--plain]
#
# `plan` designs a whole fabric from scratch and rewrites the config. This does
# the thing you actually do more often: add the machine you just built to the
# fabric you are already running, without disturbing the hosts already in it.
#
# THE DANGEROUS PART IS THE MERGE, NOT THE PROMPTING.
# The hub config holds three per-fabric lists -- BACKUP_HOSTS, PUSH_HOSTS and
# FRESHNESS -- plus hub-level settings (scheduler label prefix, retention,
# bandwidth) that existing schedulers are already named after. Writing this file
# the way `plan` does would mean regenerating all of it from whatever this run
# happened to ask about, and every host not mentioned would silently lose its
# staleness limit while the watchdog kept reporting green. So:
#
#   * only the three list assignments are ever rewritten, in place
#   * every other line of the file is passed through byte for byte
#   * hub-level settings are read and reused, never re-prompted
#
# There is a test that adds a fourth host to a three-host fabric and asserts the
# other three are unchanged. That test matters more than this command does.

set -uo pipefail
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib-validate.sh
. "$HERE/lib-validate.sh" || { echo "add-node: cannot load lib-validate.sh" >&2; exit 1; }
# shellcheck source=lib-mounts.sh
. "$HERE/lib-mounts.sh"   || { echo "add-node: cannot load lib-mounts.sh" >&2; exit 1; }
# shellcheck source=lib-host.sh
. "$HERE/lib-host.sh"     || { echo "add-node: cannot load lib-host.sh" >&2; exit 1; }

CONF_DIR="${SNAPFABRIC_CONF_DIR:-$HOME/.config/snapfabric}"
REPLACE=0; DO_PROVISION=1; ASSUME_YES=0; PLAIN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --conf)          CONF_DIR="${2:-}"; shift 2 ;;
    --replace)       REPLACE=1; shift ;;
    --no-provision)  DO_PROVISION=0; shift ;;
    --yes|-y)        ASSUME_YES=1; shift ;;
    --plain)         PLAIN=1; shift ;;
    -h|--help)
      awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    *) echo "usage: $0 [--conf DIR] [--replace] [--no-provision] [--yes] [--plain]" >&2; exit 2 ;;
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

# --- prompting helpers (identical contract to plan's) ---------------------------
# __sf_ prefixed locals, deliberately: an earlier version used __a here and in
# ask_yn's caller, and the eval assigned into the callee's local instead of the
# caller's variable. Every y/n prompt silently took the "no" branch.
ask(){ # ask <varname> <prompt> [default]
  local __sf_var="$1" __sf_prompt="$2" __sf_def="${3:-}" __sf_reply=""
  if [ -n "$__sf_def" ]; then printf "%s ${D}[%s]${N}: " "$__sf_prompt" "$__sf_def"
  else printf "%s: " "$__sf_prompt"; fi
  IFS= read -r __sf_reply || __sf_reply=""
  [ -z "$__sf_reply" ] && __sf_reply="$__sf_def"
  eval "$__sf_var=\$__sf_reply"
}
ask_valid(){ # ask_valid <validator> <varname> <prompt> [default]
  local __sf_fn="$1" __sf_var="$2" __sf_prompt="$3" __sf_def="${4:-}" __sf_v=""
  while :; do
    ask __sf_v "$__sf_prompt" "$__sf_def"
    if "$__sf_fn" "$__sf_v"; then eval "$__sf_var=\$__sf_v"; return 0; fi
    warn "not accepted: a value may not contain \" \$ \` \\ or a newline"
  done
}
ask_yn(){ # ask_yn <prompt> <default y|n> -> rc 0 for yes
  local __sf_p="$1" __sf_d="${2:-y}" __sf_r=""
  [ "$ASSUME_YES" -eq 1 ] && return 0
  while :; do
    ask __sf_r "$__sf_p ${D}(y/n)${N}" "$__sf_d"
    case "$__sf_r" in [Yy]*) return 0 ;; [Nn]*) return 1 ;; esac
  done
}

# --- load the existing fabric ---------------------------------------------------
HUB_CONF="$CONF_DIR/snapfabric.conf"
[ -r "$HUB_CONF" ] || die "no fabric at $HUB_CONF — run \`snapfabric plan\` first to create one"

BACKUP_HOSTS=""; PUSH_HOSTS=""; FRESHNESS=""; BACKUP_ROOT=""
# Read out of the hub config below and consumed by write_host_conf in
# lib-host.sh, which runs in this shell.
# shellcheck disable=SC2034
PULL_LABEL_PREFIX=""
# shellcheck disable=SC2034
BWLIMIT=0
KEEP_HOURLY=""; KEEP_DAILY=""; KEEP_WEEKLY=""; KEEP_MONTHLY=""
# shellcheck disable=SC1090
. "$HUB_CONF" || die "cannot read $HUB_CONF"
[ -n "$BACKUP_ROOT" ] || die "$HUB_CONF does not set BACKUP_ROOT"

printf "${B}Adding a node to the fabric at %s${N}\n" "$CONF_DIR"
note "  hub          ${HUB_USER:-?}@${HUB_HOST:-?}"
note "  drive        $BACKUP_ROOT"
note "  already in   ${BACKUP_HOSTS:-(none)}"
note "  retention    ${KEEP_HOURLY}h / ${KEEP_DAILY}d / ${KEEP_WEEKLY}w / ${KEEP_MONTHLY}m ${D}(reused, not re-asked)${N}"
say

# --- which host -----------------------------------------------------------------
in_list(){ case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

while :; do
  ask _tag "Name for the new host ${D}(a short tag, e.g. 'fileserver')${N}" ""
  [ -n "$_tag" ] || die "no host given — nothing added"
  safe_token "$_tag" || { warn "a host tag must be a plain word: letters, digits, - and _"; continue; }
  if in_list "$_tag" "$BACKUP_HOSTS"; then
    if [ "$REPLACE" -eq 1 ]; then
      warn "$_tag is already in the fabric — --replace given, its config will be rewritten"
      break
    fi
    warn "$_tag is already in the fabric. Pick another name, or re-run with --replace."
    continue
  fi
  break
done

TMP=$(mktemp -d) || die "cannot create a temp directory"
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

prompt_host "$_tag" "$TMP" || die "could not collect settings for $_tag"

P_MODE=""; P_FRESH=""
# shellcheck disable=SC1090
. "$TMP/h.$_tag"

# --- merge the three lists ------------------------------------------------------
# Drop any existing entry for this tag first, so --replace is idempotent and a
# repeated add cannot produce "web web" or two freshness pairs for one host.
drop_from_list(){ # drop_from_list <tag> <list>
  local t="$1" out=""
  for _x in $2; do [ "$_x" = "$t" ] || out="${out:+$out }$_x"; done
  printf '%s' "$out"
}
drop_from_fresh(){ # drop_from_fresh <tag> <pairs>
  local t="$1" out=""
  for _x in $2; do case "$_x" in "$t":*) : ;; *) out="${out:+$out }$_x" ;; esac; done
  printf '%s' "$out"
}

NEW_BACKUP_HOSTS="$(drop_from_list "$_tag" "$BACKUP_HOSTS")"
NEW_BACKUP_HOSTS="${NEW_BACKUP_HOSTS:+$NEW_BACKUP_HOSTS }$_tag"
NEW_PUSH_HOSTS="$(drop_from_list "$_tag" "$PUSH_HOSTS")"
[ "$P_MODE" = push ] && NEW_PUSH_HOSTS="${NEW_PUSH_HOSTS:+$NEW_PUSH_HOSTS }$_tag"
NEW_FRESHNESS="$(drop_from_fresh "$_tag" "$FRESHNESS")"
NEW_FRESHNESS="${NEW_FRESHNESS:+$NEW_FRESHNESS }$_tag:$P_FRESH"

# --- write the host config ------------------------------------------------------
mkdir -p "$CONF_DIR/hosts" || die "cannot create $CONF_DIR/hosts"
chmod 700 "$CONF_DIR" 2>/dev/null || true

HOST_CONF="$CONF_DIR/hosts/$_tag.conf"
HT="$TMP/host.$_tag"
write_host_conf "$_tag" "$TMP" "$HT"

say
printf "${B}%s${N} will be added:\n" "$_tag"
sed 's/^/  /' "$HT" | grep -v '^  #' | grep -v '^  $'
say
printf "${B}%s${N} will change in these lines only:\n" "$HUB_CONF"
printf "  BACKUP_HOSTS  %s\n" "$NEW_BACKUP_HOSTS"
printf "  PUSH_HOSTS    %s\n" "${NEW_PUSH_HOSTS:-(none)}"
printf "  FRESHNESS     %s\n" "$NEW_FRESHNESS"
say

if [ "$ASSUME_YES" -ne 1 ]; then
  ask_yn "Write these?" y || die "aborted — nothing written"
fi

# Rewrite exactly three assignments and pass everything else through untouched.
# A key missing from a hand-edited config is appended rather than dropped: losing
# the new host's freshness entry would leave the watchdog with no limit for it.
HUB_TMP="$TMP/hub.conf"
awk -v hosts="$NEW_BACKUP_HOSTS" -v push="$NEW_PUSH_HOSTS" -v fresh="$NEW_FRESHNESS" '
  /^BACKUP_HOSTS=/ { print "BACKUP_HOSTS=\"" hosts "\""; seen_h=1; next }
  /^PUSH_HOSTS=/   { print "PUSH_HOSTS=\""   push  "\""; seen_p=1; next }
  /^FRESHNESS=/    { print "FRESHNESS=\""    fresh "\""; seen_f=1; next }
                   { print }
  END {
    if (!seen_h) print "BACKUP_HOSTS=\"" hosts "\""
    if (!seen_p) print "PUSH_HOSTS=\""   push  "\""
    if (!seen_f) print "FRESHNESS=\""    fresh "\""
  }
' "$HUB_CONF" > "$HUB_TMP" || die "could not rewrite $HUB_CONF"
chmod 600 "$HUB_TMP"

# Sanity-check the rewrite before it lands: the result must still parse as shell
# and must still name every host that was there before. A merge that drops a
# host from the list stops its scheduler being managed, silently.
if ! bash -n "$HUB_TMP" 2>/dev/null; then
  die "the rewritten config does not parse — $HUB_CONF left untouched"
fi
for _h in $BACKUP_HOSTS; do
  in_list "$_h" "$NEW_BACKUP_HOSTS" || die "merge would have dropped host '$_h' — $HUB_CONF left untouched"
done

cp -p "$HUB_CONF" "$HUB_CONF.bak" 2>/dev/null || true
mv "$HUB_TMP" "$HUB_CONF" || die "cannot write $HUB_CONF"
chmod 600 "$HUB_CONF"
printf "  ${G}✓${N} %s ${D}(previous kept as %s.bak)${N}\n" "$HUB_CONF" "$HUB_CONF"

chmod 600 "$HT"; mv "$HT" "$HOST_CONF" || die "cannot write $HOST_CONF"
printf "  ${G}✓${N} %s\n" "$HOST_CONF"

# --- provision ------------------------------------------------------------------
say
if [ "$DO_PROVISION" -eq 0 ]; then
  cat <<EOF
${D}Nothing has been provisioned. When you are ready:

  snapfabric provision --host $_tag    install the key, agent and schedule
  snapfabric verify --host $_tag       prove a restore works, once it has run${N}
EOF
  exit 0
fi

if ! ask_yn "Provision $_tag now? ${D}(installs the backup key on it)${N}" y; then
  note "  skipped. Run: snapfabric provision --host $_tag"
  exit 0
fi

say
printf "${B}Provisioning %s${N}\n" "$_tag"
note "  You need ONE authenticated login to $_tag for this. An agent, an existing"
note "  key, or a password ssh prompts you for directly — snapfabric never reads,"
note "  stores or echoes it. After this, the fabric uses its own restricted key."
say

# An indexed array, not a string. --conf holds an operator-supplied path and
# paths here contain spaces as a matter of course -- the backup drive in the
# test fixture is "/Volumes/Backup Drive". A space-joined string reaches
# provision as four arguments (constraints 18 and 30, for the third time).
# Never empty, so there is no bash 3.2 empty-array hazard under set -u.
PROV_ARGS=(--conf "$CONF_DIR" --host "$_tag")
[ "$ASSUME_YES" -eq 1 ] && PROV_ARGS+=(--yes)
[ "$PLAIN" -eq 1 ] && PROV_ARGS+=(--plain)
bash "$HERE/snapfabric-provision.sh" "${PROV_ARGS[@]}"
rc=$?

say
if [ "$rc" -eq 0 ]; then
  printf "${G}%s is in the fabric.${N}\n" "$_tag"
  note "  Its first snapshot runs on schedule (${P_SCHED}). To take one now and prove it:"
  note "    snapfabric verify --host $_tag"
else
  bad "provisioning $_tag did not complete (exit $rc)"
  note "  The config is written, so nothing is lost. Fix the cause and re-run:"
  note "    snapfabric provision --host $_tag"
fi
exit "$rc"
