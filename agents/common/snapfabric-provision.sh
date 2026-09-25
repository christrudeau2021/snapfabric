#!/bin/bash
# snapfabric provision — install keys, agents and schedules from the plan.
#
#   usage: snapfabric-provision.sh [--conf DIR] [--host TAG] [--dry-run] [--yes]
#
# RUNS ON THE HUB. It installs launchd jobs / systemd timers locally and reaches
# out to each backed-up host over SSH.
#
# Acts only on what `plan` wrote. Idempotent: every step checks whether it is
# already done and skips if so, so re-running after a partial failure resumes
# rather than starting over.
#
# Verification is not optional here. An exit code of 0 from ssh-copy-id means a
# line was appended to a file, not that the resulting key works or that it is
# actually restricted. Every step below is followed by a check that observes the
# outcome, and a step whose check fails stops that host rather than moving on --
# a half-provisioned host that looks provisioned is the failure mode this whole
# project exists to avoid.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib-validate.sh
. "$HERE/lib-validate.sh" || { echo "provision: cannot load lib-validate.sh" >&2; exit 1; }

CONF_DIR="${SNAPFABRIC_CONF_DIR:-$HOME/.config/snapfabric}"
ONLY_HOST=""; DRY=0; ASSUME_YES=0; PLAIN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --conf)    CONF_DIR="${2:-}"; shift 2 ;;
    --host)    ONLY_HOST="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --yes|-y)  ASSUME_YES=1; shift ;;
    --plain)   PLAIN=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "usage: $0 [--conf DIR] [--host TAG] [--dry-run] [--yes]" >&2; exit 2 ;;
  esac
done

B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
{ [ -t 1 ] && [ "$PLAIN" -eq 0 ]; } || { B=""; D=""; G=""; Y=""; R=""; N=""; }

step(){ printf "    ${D}%s${N}\n" "$*"; }
good(){ printf "    ${G}✓${N} %s\n" "$*"; }
warn(){ printf "    ${Y}!${N} %s\n" "$*"; }
bad(){  printf "    ${R}✗${N} %s\n" "$*"; }
die(){  printf "${R}✗ %s${N}\n" "$*" >&2; exit 1; }

HUB_CONF="$CONF_DIR/snapfabric.conf"
[ -r "$HUB_CONF" ] || die "no config at $HUB_CONF — run \`snapfabric plan\` first"
# shellcheck disable=SC1090
. "$HUB_CONF"
: "${BACKUP_ROOT:?config must set BACKUP_ROOT}"
: "${BACKUP_HOSTS:?config must set BACKUP_HOSTS}"
: "${PULL_LABEL_PREFIX:?config must set PULL_LABEL_PREFIX}"
PUSH_HOSTS="${PUSH_HOSTS:-}"

# Where the agents get installed on the hub, and the port/user overrides the
# test harness uses to point at a throwaway sshd instead of a real host.
BIN_DIR="${SNAPFABRIC_BIN_DIR:-$HOME/bin}"
HUB_KEY="${HUB_KEY:-$HOME/.ssh/snapfabric_hub}"
REMOTE_SRC="${SNAPFABRIC_REMOTE_SRC:-$HERE/../macos/snapfabric-remote.sh}"
HUB_AUTHKEYS="${SNAPFABRIC_HUB_AUTHKEYS:-$HOME/.ssh/authorized_keys}"
LOCALHOST_PORT="${SNAPFABRIC_LOCALHOST_PORT:-22}"
SSH_PORT="${SNAPFABRIC_SSH_PORT:-22}"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -p $SSH_PORT"

LAUNCHD_DIR="${SNAPFABRIC_LAUNCHD_DIR:-$HOME/Library/LaunchAgents}"
# The Linux equivalent. macOS had an override and Linux did not, so running the
# test suite on Linux left real unit files in the operator's home -- against an
# explicit promise in both the README and the suite's own header.
SYSTEMD_DIR="${SNAPFABRIC_SYSTEMD_DIR:-$HOME/.config/systemd/user}"
NO_ACTIVATE="${SNAPFABRIC_NO_ACTIVATE:-0}"   # write the unit, do not load it (testing)

# --- calendar -------------------------------------------------------------------
# One place that turns a schedule word into a time, so launchd and systemd cannot
# drift apart.
calendar_launchd(){ # -> plist fragment
  case "$SCHEDULE" in
    hourly)  printf '    <key>StartCalendarInterval</key>\n    <dict><key>Minute</key><integer>%d</integer></dict>\n' "$OFFSET_MIN" ;;
    6h)      printf '    <key>StartCalendarInterval</key>\n    <array>\n'
             for h in 0 6 12 18; do
               printf '      <dict><key>Hour</key><integer>%d</integer><key>Minute</key><integer>%d</integer></dict>\n' "$h" "$OFFSET_MIN"
             done
             printf '    </array>\n' ;;
    daily)   printf '    <key>StartCalendarInterval</key>\n    <dict><key>Hour</key><integer>%d</integer><key>Minute</key><integer>%d</integer></dict>\n' "$((1 + OFFSET_HR))" "$OFFSET_MIN" ;;
    weekly)  printf '    <key>StartCalendarInterval</key>\n    <dict><key>Weekday</key><integer>0</integer><key>Hour</key><integer>%d</integer><key>Minute</key><integer>%d</integer></dict>\n' "$((3 + OFFSET_HR))" "$OFFSET_MIN" ;;
    monthly) printf '    <key>StartCalendarInterval</key>\n    <dict><key>Day</key><integer>1</integer><key>Hour</key><integer>%d</integer><key>Minute</key><integer>%d</integer></dict>\n' "$((4 + OFFSET_HR))" "$OFFSET_MIN" ;;
    *) return 1 ;;
  esac
}

calendar_systemd(){
  case "$SCHEDULE" in
    hourly)  printf '*-*-* *:%02d:00' "$OFFSET_MIN" ;;
    6h)      printf '*-*-* 00,06,12,18:%02d:00' "$OFFSET_MIN" ;;
    daily)   printf '*-*-* %02d:%02d:00' "$((1 + OFFSET_HR))" "$OFFSET_MIN" ;;
    weekly)  printf 'Sun *-*-* %02d:%02d:00' "$((3 + OFFSET_HR))" "$OFFSET_MIN" ;;
    monthly) printf '*-*-01 %02d:%02d:00' "$((4 + OFFSET_HR))" "$OFFSET_MIN" ;;
    *) return 1 ;;
  esac
}

# --- macOS hub ------------------------------------------------------------------
# The job does NOT invoke the engine directly. On macOS, TCC denies a launchd
# job write access to an external volume even running as root, while a process
# spawned by sshd inherits Full Disk Access. Routing through `ssh localhost` is
# the only reliable way found -- see constraint 10. It costs a loopback key and
# needs Remote Login on, which is a System Settings gate with no CLI equivalent.
install_launchd_job(){
  local plist="$LAUNCHD_DIR/$LABEL.plist" cal
  cal=$(calendar_launchd) || { bad "unknown SCHEDULE '$SCHEDULE' for $TAG"; return 1; }

  local lkey="${HUB_LOCALHOST_KEY:-$HOME/.ssh/snapfabric_localhost}"
  local lport="${SNAPFABRIC_LOCALHOST_PORT:-22}"
  if [ ! -f "$lkey" ]; then
    ssh-keygen -q -t ed25519 -N '' -f "$lkey" -C "snapfabric-localhost" </dev/null || {
      bad "could not generate the loopback key $lkey"; return 1; }
    chmod 600 "$lkey"
    good "generated loopback key $lkey"
  fi
  if ! ssh -i "$lkey" -p "$lport" -o BatchMode=yes -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new localhost true 2>/dev/null; then
    local hubak="${SNAPFABRIC_HUB_AUTHKEYS:-$HOME/.ssh/authorized_keys}"
    mkdir -p "$(dirname "$hubak")"; touch "$hubak"; chmod 600 "$hubak"
    if ! grep -qF "$(cut -d' ' -f2 <"$lkey.pub")" "$hubak" 2>/dev/null; then
      cat "$lkey.pub" >> "$hubak"; chmod 600 "$hubak"
    fi
    if ! ssh -i "$lkey" -p "$lport" -o BatchMode=yes -o ConnectTimeout=10 \
          -o StrictHostKeyChecking=accept-new localhost true 2>/dev/null; then
      bad "cannot ssh to localhost, which a macOS hub needs to reach the backup drive."
      step "Turn on System Settings → General → Sharing → Remote Login, then re-run."
      step "Without it a scheduled job is silently denied write access to $BACKUP_ROOT"
      step "by TCC — it would look scheduled and back up nothing. Refusing to install it."
      return 1
    fi
  fi
  good "loopback login works"

  mkdir -p "$LAUNCHD_DIR"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
      <string>/usr/bin/ssh</string>
      <string>-i</string><string>$lkey</string>
      <string>-p</string><string>$lport</string>
      <string>-o</string><string>BatchMode=yes</string>
      <string>localhost</string>
      <string>'$BIN_DIR/snapshot-engine.sh' '$HCONF'</string>
    </array>
$cal
    <key>StandardOutPath</key><string>$HOME/Library/Logs/snapfabric/$TAG.out</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/snapfabric/$TAG.err</string>
  </dict>
</plist>
PLIST
  mkdir -p "$HOME/Library/Logs/snapfabric"
  plutil -lint "$plist" >/dev/null 2>&1 || { bad "generated plist is malformed: $plist"; return 1; }
  good "wrote $plist"

  [ "$NO_ACTIVATE" = "1" ] && { step "not loading it (SNAPFABRIC_NO_ACTIVATE=1)"; return 0; }

  # `launchctl kickstart` silently no-ops on a job that is not loaded, so the
  # repair reports success while doing nothing. Boot out first, then bootstrap,
  # then CONFIRM by asking launchd whether the label actually exists.
  local dom; dom="gui/$(id -u)"
  launchctl bootout "$dom/$LABEL" >/dev/null 2>&1
  launchctl bootstrap "$dom" "$plist" >/dev/null 2>&1
  if launchctl print "$dom/$LABEL" >/dev/null 2>&1; then
    good "scheduler loaded: $LABEL ($SCHEDULE)"
  else
    bad "$LABEL did not load — launchctl bootstrap reported nothing but the job is absent"
    return 1
  fi
}

# --- Linux hub --------------------------------------------------------------------
install_linux_job(){
  local cal; cal=$(calendar_systemd) || { bad "unknown SCHEDULE '$SCHEDULE' for $TAG"; return 1; }
  if command -v systemctl >/dev/null 2>&1; then
    local ud="$SYSTEMD_DIR"; mkdir -p "$ud"
    cat > "$ud/$LABEL.service" <<UNIT
[Unit]
Description=snapfabric snapshot of $TAG

[Service]
Type=oneshot
ExecStart="$BIN_DIR/snapshot-engine.sh" "$HCONF"
UNIT
    cat > "$ud/$LABEL.timer" <<UNIT
[Unit]
Description=snapfabric snapshot of $TAG ($SCHEDULE)

[Timer]
OnCalendar=$cal
Persistent=true

[Install]
WantedBy=timers.target
UNIT
    # Validate the generated unit, the way the macOS path runs plutil -lint.
    if command -v systemd-analyze >/dev/null 2>&1; then
      if ! systemd-analyze verify "$ud/$LABEL.timer" >/dev/null 2>&1; then
        bad "generated unit is malformed: $ud/$LABEL.timer"; return 1
      fi
    fi
    good "wrote $ud/$LABEL.timer"
    [ "$NO_ACTIVATE" = "1" ] && { step "not enabling it (SNAPFABRIC_NO_ACTIVATE=1)"; return 0; }
    systemctl --user daemon-reload >/dev/null 2>&1
    systemctl --user enable --now "$LABEL.timer" >/dev/null 2>&1

    # is-enabled is not enough. A --user timer does not run while the user is
    # not logged in unless lingering is on, and Persistent=true does not save
    # it: a headless hub installs cleanly, reports "timer enabled", and never
    # fires once. Refusing here rather than reporting a success that is not one.
    if ! systemctl --user is-enabled "$LABEL.timer" >/dev/null 2>&1; then
      bad "$LABEL.timer did not enable"
      return 1
    fi
    if command -v loginctl >/dev/null 2>&1; then
      if [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" != "yes" ]; then
        bad "$LABEL.timer is enabled but will NOT run: user lingering is off, so"
        step "systemd stops your user manager at logout and the timer never fires."
        step "Fix with:  sudo loginctl enable-linger $(id -un)"
        step "Then re-run provision. Refusing to report this host as scheduled."
        return 1
      fi
      good "lingering is on — the timer will run while logged out"
    else
      warn "cannot check user lingering (no loginctl). If this hub is headless,"
      warn "confirm 'loginctl show-user $(id -un) -p Linger' says yes."
    fi
    good "timer enabled: $LABEL ($cal)"
  else
    warn "no systemd — falling back to cron, which does NOT catch up a missed run"
    local line="# snapfabric:$LABEL"
    # This check lived inside the systemd branch only, so on a systemd-less box
    # the test suite wrote into the operator's REAL crontab -- the one thing
    # both the README and the suite header promise never happens.
    if [ "$NO_ACTIVATE" = "1" ]; then
      step "not installing a crontab entry (SNAPFABRIC_NO_ACTIVATE=1)"
      return 0
    fi
    ( crontab -l 2>/dev/null | grep -v "$line"
      case "$SCHEDULE" in
        hourly)  printf '%d * * * * \047%s\047 \047%s\047 %s\n' "$OFFSET_MIN" "$BIN_DIR/snapshot-engine.sh" "$HCONF" "$line" ;;
        6h)      printf '%d 0,6,12,18 * * * \047%s\047 \047%s\047 %s\n' "$OFFSET_MIN" "$BIN_DIR/snapshot-engine.sh" "$HCONF" "$line" ;;
        daily)   printf '%d %d * * * \047%s\047 \047%s\047 %s\n' "$OFFSET_MIN" "$((1+OFFSET_HR))" "$BIN_DIR/snapshot-engine.sh" "$HCONF" "$line" ;;
        weekly)  printf '%d %d * * 0 \047%s\047 \047%s\047 %s\n' "$OFFSET_MIN" "$((3+OFFSET_HR))" "$BIN_DIR/snapshot-engine.sh" "$HCONF" "$line" ;;
        monthly) printf '%d %d 1 * * \047%s\047 \047%s\047 %s\n' "$OFFSET_MIN" "$((4+OFFSET_HR))" "$BIN_DIR/snapshot-engine.sh" "$HCONF" "$line" ;;
      esac
    ) | crontab - || { bad "could not install crontab entry"; return 1; }
    crontab -l 2>/dev/null | grep -q "$line" && good "cron entry installed" || { bad "cron entry missing after install"; return 1; }
  fi
}

printf "${B}snapfabric provision${N}  ${D}%s${N}\n" "$CONF_DIR"
[ "$DRY" -eq 1 ] && printf "${Y}dry run — nothing will be changed${N}\n"
echo

# --- hub preflight -------------------------------------------------------------
# Checked here as well as in the engine. The operator should learn that the
# drive is missing while provisioning, not from a scheduled job at 01:00.
printf "${B}hub${N}\n"
if [ ! -d "$BACKUP_ROOT" ]; then
  die "$BACKUP_ROOT does not exist — is the backup drive connected?"
fi
dest_dev=$(df -P "$BACKUP_ROOT" 2>/dev/null | awk 'NR==2{print $1}')
for sysmount in / /System/Volumes/Data /home /var; do
  [ -d "$sysmount" ] || continue
  d=$(df -P "$sysmount" 2>/dev/null | awk 'NR==2{print $1}')
  if [ -n "$d" ] && [ "$d" = "$dest_dev" ]; then
    [ "${ALLOW_SYSTEM_DISK:-0}" = "1" ] \
      && { warn "$BACKUP_ROOT is on the system disk — permitted by ALLOW_SYSTEM_DISK=1"; break; }
    die "$BACKUP_ROOT is on the hub's system disk ($dest_dev). If the drive is
   unplugged its mount point is still an ordinary directory, and backups would
   fill the boot volume. Refusing."
  fi
done
good "$BACKUP_ROOT on $dest_dev"

# --- hub verb API key ------------------------------------------------------------
# `status` and `doctor` authenticate to the hub with HUB_KEY and are answered by
# the forced command installed here. Nothing generated this key before, so both
# commands failed for anyone who had not built the hub by hand.
#
# The key is restricted the same way the per-node backup keys are, and for the
# same reason: `doctor` is meant to run from a SECOND machine, so this private
# key leaves the hub. If it granted a shell, the watchdog host would own the hub
# -- and the hub holds every backup. It is restricted to the verb API, and that
# restriction is measured below rather than assumed.
install_hub_key(){
  local pub line ak="$HUB_AUTHKEYS"

  if [ ! -f "$HUB_KEY" ]; then
    if [ "$DRY" -eq 1 ]; then step "would generate $HUB_KEY"; return 0; fi
    ssh-keygen -q -t ed25519 -N '' -f "$HUB_KEY" -C "snapfabric-hub" </dev/null \
      || { bad "could not generate $HUB_KEY"; return 1; }
    chmod 600 "$HUB_KEY"
    good "generated $HUB_KEY"
  else
    step "hub key exists: $HUB_KEY"
  fi
  [ "$DRY" -eq 1 ] && { step "would install the verb-API forced command for $HUB_KEY"; return 0; }

  pub=$(cat "$HUB_KEY.pub") || { bad "cannot read $HUB_KEY.pub"; return 1; }
  mkdir -p "$(dirname "$ak")"; touch "$ak"; chmod 600 "$ak"
  line=$(printf 'command="%s/snapfabric-remote",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc %s' \
    "$BIN_DIR" "$pub")

  # A no-op when the line is already exactly right. Rewriting unconditionally
  # still produced the correct file, but it moved this line to the end on every
  # run -- so authorized_keys changed on a re-run that should have changed
  # nothing, and "provision is idempotent" quietly stopped being true.
  if grep -qxF "$line" "$ak" 2>/dev/null; then
    step "verb-API forced command already installed"
    return 0
  fi
  # Replace this key's own line rather than appending a second one.
  grep -v 'snapfabric-hub$' "$ak" > "$ak.new" 2>/dev/null || : > "$ak.new"
  printf '%s\n' "$line" >> "$ak.new"
  mv "$ak.new" "$ak"; chmod 600 "$ak"
  good "installed the verb-API forced command on the hub"
}

verify_hub_key(){
  [ "$DRY" -eq 1 ] && { step "would verify: shell denied, ping verb allowed"; return 0; }
  local o="-i $HUB_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -p $LOCALHOST_PORT"
  local vfail=0

  # 1. A shell must be refused. An unrestricted key here would mean the watchdog
  #    host owns the machine holding every backup.
  # shellcheck disable=SC2086
  if ssh $o localhost 'echo shell-allowed' 2>/dev/null | grep -q shell-allowed; then
    bad "the hub key grants a SHELL — the forced command is not in effect"; vfail=1
  else
    good "verified: hub shell denied"
  fi

  # 2. The API must actually answer, or status/doctor are dead in a subtler way.
  # shellcheck disable=SC2086
  if ssh $o localhost "$BIN_DIR/snapfabric-remote ping" 2>/dev/null | grep -q '^ok '; then
    good "verified: hub verb API answers"
  else
    bad "the verb API did not answer — status and doctor will report UNREACHABLE"; vfail=1
  fi

  [ "$vfail" -eq 0 ]
}


if [ "$DRY" -eq 0 ]; then
  mkdir -p "$BIN_DIR" || die "cannot create $BIN_DIR"
  for a in snapshot-engine.sh lib-validate.sh; do
    if [ ! -f "$BIN_DIR/$a" ] || ! cmp -s "$HERE/$a" "$BIN_DIR/$a"; then
      cp "$HERE/$a" "$BIN_DIR/$a" && chmod 755 "$BIN_DIR/$a" || die "cannot install $a"
      good "installed $BIN_DIR/$a"
    else
      step "$a already current"
    fi
  done
  # The verb API. `status` and `doctor` reach the hub through nothing else, so
  # omitting it made both commands fail with UNREACHABLE / CRITICAL on a
  # perfectly healthy fabric. It only ever worked on the machine this was built
  # on because it had been copied there by hand -- the exact "works here, fails
  # for everyone else" failure this project exists to catch.
  # Installed WITHOUT the .sh suffix: that is the name plan writes into
  # REMOTE_CMD and the name the forced command below must match.
  if [ ! -f "$BIN_DIR/snapfabric-remote" ] || ! cmp -s "$REMOTE_SRC" "$BIN_DIR/snapfabric-remote"; then
    cp "$REMOTE_SRC" "$BIN_DIR/snapfabric-remote" \
      && chmod 755 "$BIN_DIR/snapfabric-remote" || die "cannot install snapfabric-remote"
    good "installed $BIN_DIR/snapfabric-remote"
  else
    step "snapfabric-remote already current"
  fi
else
  step "would install snapshot-engine.sh, lib-validate.sh and snapfabric-remote into $BIN_DIR"
fi

# Ordered deliberately: the forced command points at $BIN_DIR/snapfabric-remote,
# so verifying it before the agent install above would test a path that does not
# exist yet and report a working API as broken.
if install_hub_key && verify_hub_key; then
  :
else
  warn "the hub verb API is not working: \`snapfabric status\` and \`snapfabric doctor\`"
  warn "will report the hub as unreachable. Backups themselves are unaffected."
fi
echo

# --- per-host ------------------------------------------------------------------
is_push(){ for _p in $PUSH_HOSTS; do [ "$_p" = "$1" ] && return 0; done; return 1; }

provisioned=0; skipped=0; failed=0; failed_hosts=""

for TAG in $BACKUP_HOSTS; do
  [ -n "$ONLY_HOST" ] && [ "$ONLY_HOST" != "$TAG" ] && continue
  printf "${B}%s${N}\n" "$TAG"

  HCONF="$CONF_DIR/hosts/$TAG.conf"
  if [ ! -r "$HCONF" ]; then
    bad "no host config at $HCONF — re-run \`snapfabric plan\`"
    failed=$((failed+1)); failed_hosts="$failed_hosts $TAG"; echo; continue
  fi

  # Each host's config is read in a subshell-free but scoped way: unset first so
  # a value missing from one host cannot be inherited from the previous one.
  # HOST_TAG/EXCLUDES are read by the engine from this same file, not by us; they
  # are cleared here so one host cannot inherit the previous host's value.
  # shellcheck disable=SC2034
  HOST_TAG=""; SSH_USER=""; SSH_HOST=""; SSH_KEY=""; SOURCES=""
  # shellcheck disable=SC2034
  EXCLUDES=""; SSH_PORT=""; SCHEDULE=""; SENTINEL=""
  # Where the key and wrapper land ON THE BACKED-UP HOST. Overridable because
  # not every host uses the defaults -- a host whose sshd sets a non-default
  # AuthorizedKeysFile would otherwise be provisioned into a file it never reads,
  # which fails in the worst way: silently, and looking like success.
  REMOTE_BIN=""; REMOTE_AUTHKEYS=""
  # shellcheck disable=SC1090
  . "$HCONF"
  : "${SSH_USER:?$TAG config must set SSH_USER}"
  : "${SSH_HOST:?$TAG config must set SSH_HOST}"
  : "${SSH_KEY:=$HOME/.ssh/snapfabric_$TAG}"
  : "${REMOTE_BIN:=\$HOME/bin}"
  : "${REMOTE_AUTHKEYS:=\$HOME/.ssh/authorized_keys}"
  # Per host, not global: an estate can mix ports. Provision must probe the same
  # port the engine will later use, or it verifies a host the backup never reaches.
  SSH_PORT="${SSH_PORT:-${SNAPFABRIC_SSH_PORT:-22}}"
  SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -p $SSH_PORT"
  # Anything that asks what a SPECIFIC key permits must offer only that key.
  # Without IdentitiesOnly, ssh also offers agent keys and the operator's
  # defaults, so "does this key grant a shell?" gets answered by whichever key
  # happens to work -- and a correctly restricted host is refused because an
  # agent key let the shell through. Bootstrap deliberately does NOT use this:
  # its whole job is to get in with some other credential.
  VOPTS="$SSH_OPTS -o IdentitiesOnly=yes"

  if is_push "$TAG"; then
    step "push host — the agent runs on $TAG, so there is nothing to schedule here"
    step "install $BIN_DIR/snapshot-engine.sh and $HCONF on $TAG and schedule it there"
    skipped=$((skipped+1)); echo; continue
  fi

  FIRST_SRC=$(printf '%s' "$SOURCES" | head -1)
  [ -n "$FIRST_SRC" ] || { bad "no SOURCES in $HCONF"; failed=$((failed+1)); failed_hosts="$failed_hosts $TAG"; echo; continue; }

  # --- 1. key ------------------------------------------------------------------
  if [ -f "$SSH_KEY" ]; then
    step "key exists: $SSH_KEY"
  elif [ "$DRY" -eq 1 ]; then
    step "would generate $SSH_KEY"
  else
    # Passphraseless by necessity: this key is used by an unattended scheduled
    # job. That is exactly why it is restricted to read-only rsync below.
    ssh-keygen -q -t ed25519 -N '' -f "$SSH_KEY" -C "snapfabric-$TAG" </dev/null \
      || { bad "could not generate $SSH_KEY"; failed=$((failed+1)); failed_hosts="$failed_hosts $TAG"; echo; continue; }
    chmod 600 "$SSH_KEY"
    good "generated $SSH_KEY"
  fi

  # --- 2. is it already working? -----------------------------------------------
  # Idempotency check comes before installation, so a re-run of provision does
  # not append a duplicate key line. Two identical keys in authorized_keys is
  # harmless, but it is also how a hub ended up needing a manual dedupe.
  key_works=0
  if [ -f "$SSH_KEY" ]; then
    if rsync --list-only -e "ssh -i $SSH_KEY $VOPTS" \
         "$SSH_USER@$SSH_HOST:$FIRST_SRC/" >/dev/null 2>&1; then
      key_works=1
      step "key already authorised on $SSH_HOST"
    fi
  fi

  # --- 3. install the key + forced command -------------------------------------
  if [ "$key_works" -eq 0 ]; then
    if [ "$DRY" -eq 1 ]; then
      step "would install the restricted key on $SSH_USER@$SSH_HOST"
    else
      # We need one authenticated login to bootstrap. Any existing method is
      # fine -- agent, another key, or a password typed once. The password is
      # never read, stored or echoed by snapfabric: ssh prompts for it directly.
      if ssh $SSH_OPTS -o BatchMode=yes "$SSH_USER@$SSH_HOST" true 2>/dev/null; then
        BOOTSTRAP="ssh $SSH_OPTS -o BatchMode=yes"
      elif [ "$ASSUME_YES" -eq 1 ]; then
        bad "no non-interactive login to $SSH_USER@$SSH_HOST and --yes forbids prompting"
        failed=$((failed+1)); failed_hosts="$failed_hosts $TAG"; echo; continue
      else
        warn "no key-based login to $SSH_USER@$SSH_HOST yet — ssh will prompt for a password"
        warn "snapfabric never reads or stores it; ssh handles it directly"
        BOOTSTRAP="ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -p $SSH_PORT"
      fi

      PUB=$(cat "$SSH_KEY.pub") || { bad "cannot read $SSH_KEY.pub"; failed=$((failed+1)); failed_hosts="$failed_hosts $TAG"; echo; continue; }
      WRAPPER=$(cat "$HERE/snapfabric-rsync-only.sh")

      # Sent over stdin rather than as a command line so nothing here depends on
      # remote quoting. The remote script is plain and does its own checking.
      if $BOOTSTRAP "$SSH_USER@$SSH_HOST" 'bash -s' <<REMOTE
set -eu
umask 077
BIN="$REMOTE_BIN"
AK="$REMOTE_AUTHKEYS"
mkdir -p "\$BIN" "\$(dirname "\$AK")"
cat > "\$BIN/snapfabric-rsync-only" <<'WRAPEOF'
$WRAPPER
WRAPEOF
chmod 755 "\$BIN/snapfabric-rsync-only"
touch "\$AK"; chmod 600 "\$AK"
# Idempotent: replace any previous snapfabric line for this tag rather than
# appending a second one. Two identical keys are harmless, but a hub
# did end up needing a dedupe after a repeated ssh-copy-id.
grep -v 'snapfabric-$TAG\$' "\$AK" > "\$AK.new" || true
printf 'command="%s/snapfabric-rsync-only",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc %s\n' \
  "\$BIN" '$PUB' >> "\$AK.new"
mv "\$AK.new" "\$AK"
chmod 600 "\$AK"
REMOTE
      then
        good "installed restricted key and forced command on $SSH_HOST"
      else
        bad "could not install the key on $SSH_USER@$SSH_HOST"
        failed=$((failed+1)); failed_hosts="$failed_hosts $TAG"; echo; continue
      fi
    fi
  fi

  # --- 4. verify the restriction, empirically ----------------------------------
  # The plan doc is explicit that this must be measured rather than assumed:
  # `rrsync -ro /` is not a real restriction, and a forced command that is
  # subtly wrong fails open. Three observations, all required.
  if [ "$DRY" -eq 1 ]; then
    step "would verify: shell denied, rsync read allowed, rsync write denied"
  else
    vfail=0

    if ssh -i "$SSH_KEY" $VOPTS "$SSH_USER@$SSH_HOST" 'echo SHELL_GRANTED' 2>/dev/null | grep -q SHELL_GRANTED; then
      bad "the key grants a SHELL on $SSH_HOST — refusing to treat this host as provisioned"
      vfail=1
    else
      good "shell denied"
    fi

    if rsync --list-only -e "ssh -i $SSH_KEY $VOPTS" \
         "$SSH_USER@$SSH_HOST:$FIRST_SRC/" >/dev/null 2>&1; then
      good "rsync read works ($FIRST_SRC)"
    else
      bad "rsync cannot read $FIRST_SRC — the backup would fail every run"
      vfail=1
    fi

    # A backup key that can write is a backup key that ransomware can use.
    wtmp=$(mktemp -d)
    : > "$wtmp/.snapfabric-write-probe"
    if rsync -q -e "ssh -i $SSH_KEY $VOPTS" \
         "$wtmp/.snapfabric-write-probe" "$SSH_USER@$SSH_HOST:/tmp/" >/dev/null 2>&1; then
      bad "the key can WRITE to $SSH_HOST — the forced command is not restricting --sender"
      vfail=1
    else
      good "rsync write denied"
    fi
    rm -rf "$wtmp"

    if [ "$vfail" -ne 0 ]; then
      bad "$TAG failed verification — not scheduling it"
      failed=$((failed+1)); failed_hosts="$failed_hosts $TAG"; echo; continue
    fi
  fi

  # --- 5. sentinel ---------------------------------------------------------------
  # An unmounted source presents as an empty directory, and rsync --delete then
  # faithfully propagates the emptiness over a good backup. SENTINEL is a path
  # that must be visible on the source before the engine will run.
  #
  # The engine enforces this ONLY when SENTINEL is set. So there are two honest
  # outcomes and they are not the same: a set-but-unreachable sentinel is a hard
  # failure, because every scheduled run will abort at preflight and a host that
  # can never run must not be reported as provisioned. An unset sentinel is a
  # gap in protection, not a broken host, so it is called out and allowed.
  if [ "$DRY" -eq 0 ]; then
    if [ -n "${SENTINEL:-}" ]; then
      if rsync --list-only -e "ssh -i $SSH_KEY $VOPTS" \
           "$SSH_USER@$SSH_HOST:$SENTINEL" >/dev/null 2>&1; then
        good "sentinel visible: $SENTINEL"
      else
        bad "sentinel $SENTINEL is not visible on $SSH_HOST"
        step "The engine refuses to run without it, so every scheduled run would abort."
        step "Fix the path in $HCONF, or clear SENTINEL to disable the check."
        failed=$((failed+1)); failed_hosts="$failed_hosts $TAG"; echo; continue
      fi
    else
      warn "no SENTINEL set for $TAG — an unmounted source cannot be detected"
      step "If any source is a mount point, set SENTINEL in $HCONF to a file"
      step "inside it. Without one, an unmounted source looks like an empty"
      step "directory and --delete would propagate that over a good backup."
    fi
  fi

  # --- 6. scheduler --------------------------------------------------------------
  LABEL="${PULL_LABEL_PREFIX}.${TAG}"
  : "${SCHEDULE:=daily}"
  # Stagger by position so several daily jobs do not contend for one USB spindle.
  HOST_INDEX=0; _i=0
  for _h in $BACKUP_HOSTS; do [ "$_h" = "$TAG" ] && HOST_INDEX=$_i; _i=$((_i+1)); done
  OFFSET_MIN=$(( (HOST_INDEX * 30) % 60 ))
  OFFSET_HR=$(( HOST_INDEX / 2 ))

  if [ "$DRY" -eq 1 ]; then
    step "would schedule $LABEL ($SCHEDULE)"
  else
    case "$(uname -s)" in
      Darwin) install_launchd_job || { failed=$((failed+1)); failed_hosts="$failed_hosts $TAG"; echo; continue; } ;;
      *)      install_linux_job   || { failed=$((failed+1)); failed_hosts="$failed_hosts $TAG"; echo; continue; } ;;
    esac
  fi

  provisioned=$((provisioned+1))
  echo
done

# --- summary ---------------------------------------------------------------------
printf "${B}summary${N}\n"
printf "  %d provisioned, %d skipped, %d failed\n" "$provisioned" "$skipped" "$failed"
if [ "$failed" -ne 0 ]; then
  printf "  ${R}failed:%s${N}\n" "$failed_hosts"
  printf "  ${D}provision is idempotent — fix the cause and run it again.${N}\n"
  exit 1
fi
printf "\n  ${D}Next: snapfabric verify — prove a restore works before trusting any of this.${N}\n"
