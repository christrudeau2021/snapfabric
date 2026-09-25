#!/bin/bash
# Behaviour tests for the rules in docs/CONSTRAINTS.md.
#
# Each rule here was learned from a real failure, so each gets a test that fails
# if the behaviour regresses. These run entirely offline — no hub, no network.
#
#   usage: tests/test-constraints.sh

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/agents/common/snapshot-engine.sh"
REMOTE="$ROOT/agents/macos/snapfabric-remote.sh"
PLAN="$ROOT/agents/common/snapfabric-plan.sh"
LIB="$ROOT/agents/common/lib-validate.sh"
MOUNTLIB="$ROOT/agents/common/lib-mounts.sh"
WATCHDOG="$ROOT/agents/common/snapfabric-doctor.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

ok(){   printf "  \033[32mPASS\033[0m  %s\n" "$1"; pass=$((pass+1)); }
bad(){  printf "  \033[31mFAIL\033[0m  %s\n" "$1"; fail=$((fail+1)); }
check(){ if [ "$1" = "0" ]; then ok "$2"; else bad "$2"; fi; }

echo "snapfabric constraint tests"
echo

# --- 17: the system-disk guard must actually fire -----------------------------
# First implementation compared only against "/", which on macOS is the sealed
# system volume, so the guard silently passed for internal-disk paths.
mkdir -p "$TMP/dest"
cat > "$TMP/sys.conf" <<EOF
HOST_TAG="t"; SSH_USER="u"; SSH_HOST="127.0.0.1"; DEST_ROOT="$TMP/dest"; SOURCES="/tmp"
EOF
out=$(LOG_DIR="$TMP/logs" "$ENGINE" "$TMP/sys.conf" --dry-run 2>&1)
echo "$out" | grep -q "on the system disk" && ok "system-disk guard refuses a path on the internal disk" \
                                           || bad "system-disk guard did NOT fire"

# and must be overridable deliberately
rm -rf "$TMP/logs"
out=$(ALLOW_SYSTEM_DISK=1 LOG_DIR="$TMP/logs" "$ENGINE" "$TMP/sys.conf" --dry-run 2>&1)
echo "$out" | grep -q "permitted by ALLOW_SYSTEM_DISK" && ok "guard is overridable with an explicit opt-in" \
                                                       || bad "ALLOW_SYSTEM_DISK override does not work"

# --- 18: paths and excludes containing spaces ---------------------------------
# Unquoted word-splitting tore "/srv/My Documents" into two bogus sources.
cat > "$TMP/space.conf" <<EOF
HOST_TAG="t2"; SSH_USER="u"; SSH_HOST="127.0.0.1"; DEST_ROOT="$TMP/dest"
SOURCES="/opt
/srv/My Documents"
EXCLUDES=".cache/
/My Cache/"
EOF
rm -rf "$TMP/logs"
RSYNC=/bin/echo ALLOW_SYSTEM_DISK=1 LOG_DIR="$TMP/logs" "$ENGINE" "$TMP/space.conf" --dry-run >/dev/null 2>&1
grep -q "syncing /srv/My Documents" "$TMP/logs/t2.log" && ok "source path with a space stays intact" \
                                                       || bad "source path with a space was split"
grep -q -- "--exclude=/My Cache/" "$TMP/logs/t2.log" && ok "exclude pattern with a space stays one argument" \
                                                     || bad "exclude pattern with a space was split"

# --- 5: no python3 dependency in the agents -----------------------------------
# /usr/bin/python3 on macOS is a stub that triggers an Xcode prompt; a backup
# agent must not depend on it.
if grep -vE '^\s*#' "$ENGINE" | grep -q "python3"; then
  bad "engine still calls python3 outside comments"
else ok "engine has no python3 runtime dependency"; fi

# --- 15: bash 3.2 compatibility ------------------------------------------------
if grep -qE '^\s*(declare -A|mapfile|readarray)' "$ENGINE" "$REMOTE"; then
  bad "bash 4-only construct present (macOS ships bash 3.2)"
else ok "no bash 4-only constructs"; fi

# --- 6: failures keep their dated name ----------------------------------------
# Renaming to FAILED_* hid partials from the resume path and filled a volume.
# Strip comments first: the engine *documents* why it does not rename, and a
# naive grep matches that explanation and reports a false failure.
if grep -vE '^\s*#' "$ENGINE" | grep -qE 'mv .*FAILED_|FAILED_\$STAMP'; then
  bad "engine still renames failed runs to FAILED_"
else ok "failed runs keep their dated name so the next run resumes"; fi

# --- 7: retention runs on the failure path too --------------------------------
awk '/rc_total" -ne 0/,/^fi$/' "$ENGINE" | grep -q "failure pruning" \
  && ok "retention prunes on the failure path" \
  || bad "failure path does not prune — partials will accumulate forever"

# --- 7b: ENOSPC deadlock guard -------------------------------------------------
grep -q "ENOSPC deadlock" "$ENGINE" && ok "discards its own partial when the volume is nearly full" \
                                    || bad "no ENOSPC deadlock guard"

# --- 12/19: dispatcher refuses everything outside the allowlists ---------------
cat > "$TMP/remote.conf" <<'EOF'
BACKUP_ROOT="/tmp"; BACKUP_HOSTS="alpha beta"
MANAGED_VOLUMES="Backups
My Backup Drive"
PUSH_HOSTS="beta"; PULL_LABEL_PREFIX="com.test.pull"; ADVERTISER_LABEL=""
EOF
r(){ SNAPFABRIC_CONF="$TMP/remote.conf" SSH_ORIGINAL_COMMAND="$1" bash "$REMOTE" 2>&1; }
for probe in "id" "sudo id" "status; id" "ping && id" "mount NotAVolume" \
             "restart-service com.apple.smbd" "run-backup ../../etc"; do
  out=$(r "$probe")
  echo "$out" | grep -q "refused" && ok "refused: $probe" || bad "ALLOWED: $probe -> $out"
done

# A macOS volume name with spaces must be usable through the verb API. Splitting
# the request on spaces made "My Backup Drive" arrive as four arguments
# and be refused -- and that is Apple's own default Time Machine volume name, so
# the tool was broken for a large share of real drives.
out=$(r "mount My Backup Drive")
if echo "$out" | grep -q "volume not allowed"; then
  bad "an allowlisted volume name containing spaces was refused"
else
  ok "allowlisted volume name with spaces is accepted by the verb API"
fi

# ...and one that is NOT on the list still must not be.
out=$(r "mount Some Other Drive")
echo "$out" | grep -q "refused" && ok "refused: a volume with spaces that is not allowlisted" \
                                || bad "ALLOWED an unlisted spaced volume: $out"

# constraint 19: a push host has no hub-side scheduler, so triggering it must
# be refused rather than silently doing nothing
out=$(r "run-backup beta")
echo "$out" | grep -q "no scheduler for host" && ok "refused: run-backup on a push host" \
                                              || bad "push host was treated as triggerable"

# and a legitimate verb must still work
out=$(r "ping"); echo "$out" | grep -q '^ok' && ok "allowed: ping" || bad "ping broke: $out"

# --- 21: `plan` writes what the engine can read -------------------------------
# The tests above check the READER against hand-written configs. They all pass
# even if the WRITER emits something the reader mangles -- which is the half
# that had never been exercised. Drive plan from a here-doc and feed its output
# straight into the engine.
plan_run(){ # plan_run <outdir>  (answers on stdin)
  bash "$PLAN" --out "$1" --plain >"$1/plan.out" 2>&1
}

P1="$TMP/p1"; mkdir -p "$P1"
plan_run "$P1" <<'EOF'
tester
192.0.2.10

/Volumes/NotPresentHere
Backups

fileserver
tester
192.0.2.11
22
n
n
/srv/My Documents
/opt

default
/My Cache/

weekly

local.test.pull




0
y
EOF

if [ -f "$P1/hosts/fileserver.conf" ]; then
  ok "plan writes a host config"
else
  bad "plan produced no host config"
fi

# Round-trip: the emitted config, consumed by the engine, must keep a
# space-containing source as ONE source and a space-containing exclude as ONE
# argument. Space-joining SOURCES here would reintroduce constraint 18 while
# every existing test stayed green.
mkdir -p "$P1/dest"
sed "s|^DEST_ROOT=.*|DEST_ROOT=\"$P1/dest\"|" "$P1/hosts/fileserver.conf" > "$P1/rt.conf" 2>/dev/null
RSYNC=/bin/echo ALLOW_SYSTEM_DISK=1 LOG_DIR="$P1/logs" "$ENGINE" "$P1/rt.conf" --dry-run >/dev/null 2>&1
# Anchored, and the count is checked too. An unanchored match is useless here:
# space-joining the two sources yields the single line "syncing /srv/My
# Documents /opt", which a substring match happily accepts. Verified by
# mutating the writer to space-join and confirming this test goes red.
n_sync=$(grep -c "^\[.*\] syncing /" "$P1/logs/fileserver.log" 2>/dev/null || echo 0)
if grep -q "syncing /srv/My Documents$" "$P1/logs/fileserver.log" 2>/dev/null && [ "$n_sync" -eq 2 ]; then
  ok "plan → engine round-trip keeps a source path with a space intact"
else
  bad "plan-written SOURCES was mangled: $n_sync sources, $(grep 'syncing' "$P1/logs/fileserver.log" 2>/dev/null | head -1)"
fi
if grep -q -- "--exclude=/My Cache/" "$P1/logs/fileserver.log" 2>/dev/null; then
  ok "plan → engine round-trip keeps an exclude with a space intact"
else
  bad "plan-written EXCLUDES was split by the engine"
fi

# Freshness must follow the schedule. Asking for both independently lets an
# operator pick a weekly job and a 30-hour limit, and the watchdog then reports
# CRITICAL on a permanently healthy host.
if grep -q 'FRESHNESS="fileserver:210"' "$P1/snapfabric.conf" 2>/dev/null; then
  ok "freshness is derived from the schedule (weekly → 210h)"
else
  bad "freshness not derived from schedule: $(grep FRESHNESS "$P1/snapfabric.conf" 2>/dev/null)"
fi

# --- 22: plan is an injection sink and must validate what it writes -----------
# The config is SOURCED. An operator pasting a path containing $(...) must not
# turn into command execution the next time any agent reads that file.
P2="$TMP/p2"; mkdir -p "$P2"
plan_run "$P2" <<EOF
tester
192.0.2.10

/Volumes/NotPresentHere
Backups

evil
tester
192.0.2.11
22
n
n
/srv/\$(touch $TMP/PWNED)/x
/opt


daily

local.test.pull




0
y
EOF

if grep -q 'PWNED' "$P2/hosts/evil.conf" 2>/dev/null; then
  bad "plan wrote an unvalidated command substitution into a sourced config"
else
  ok "plan refuses a source path containing a command substitution"
fi
# and prove it by sourcing the result the way an agent would
( . "$P2/hosts/evil.conf" ) >/dev/null 2>&1
if [ -e "$TMP/PWNED" ]; then
  bad "sourcing a plan-written config executed operator input"
else
  ok "sourcing a plan-written config executes nothing"
fi

# Configs hold hostnames, key paths and the shape of the whole estate.
mode=$(ls -l "$P2/hosts/evil.conf" 2>/dev/null | awk '{print $1}')
case "$mode" in
  -rw-------*) ok "plan writes configs mode 0600" ;;
  *)           bad "plan wrote a world- or group-readable config ($mode)" ;;
esac

# --- 28: freshness must come from the last COMPLETED run ---------------------
# The dispatcher reported the newest snapshot DIRECTORY and status called it
# "latest". A run in progress, or a failed one, creates a newer directory --
# so a host whose last good backup was 10 days old displayed as 4 hours fresh
# and the dashboard said ALL GREEN. Found by `verify` on the real estate.
SNAPROOT="$TMP/snaproot"
mkdir -p "$SNAPROOT/alpha/2026-01-01_000000" "$SNAPROOT/alpha/2026-06-01_000000"
ln -s "$SNAPROOT/alpha/2026-01-01_000000" "$SNAPROOT/alpha/latest"
cat > "$TMP/snap.conf" <<EOF
BACKUP_ROOT="$SNAPROOT"; MANAGED_VOLUMES="none"; BACKUP_HOSTS="alpha"
PUSH_HOSTS=""; PULL_LABEL_PREFIX="com.test.pull"; ADVERTISER_LABEL=""
EOF
snapline=$(SNAPFABRIC_CONF="$TMP/snap.conf" SSH_ORIGINAL_COMMAND="status" \
           bash "$REMOTE" 2>/dev/null | grep '^SNAP|alpha|')
newest_f=$(printf '%s' "$snapline" | cut -d'|' -f4)
good_f=$(printf '%s' "$snapline" | cut -d'|' -f5)
if [ "$newest_f" = "2026-06-01_000000" ] && [ "$good_f" = "2026-01-01_000000" ]; then
  ok "status reports the last COMPLETED snapshot separately from the newest directory"
else
  bad "newest/last-good not distinguished (newest='$newest_f' good='$good_f')"
fi

# --- 29: the mount scan must be usable, not merely correct -------------------
# First run of this on a Mac with Time Machine returned 26 filesystems, 23 of
# them local-snapshot mounts. Technically accurate; completely unusable as a
# menu, which makes it no better than asking the operator to type a path.
cat > "$TMP/df.out" <<'EOF'
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/disk1s1 976000000 40000000 936000000 4% /
devfs 200 200 0 100% /dev
map auto_home 0 0 0 100% /System/Volumes/Data/home
/dev/disk9s1 15000000000 4500000000 10500000000 30% /Volumes/My Backup Drive
/dev/disk1s5 976000000 500000 975500000 1% /Volumes/com.apple.TimeMachine.localsnapshots/Backups.backupdb/Mac/2026-01-01-000000/Data
//user@nas._smb._tcp.local/share 500000000 100000000 400000000 20% /Volumes/.timemachine/1.2.3.4/AAAA/TM
tmpfs 8000000 0 8000000 0% /run
/dev/sdb1 2000000000 100000000 1900000000 5% /mnt/bulk
overlay 976000000 40000000 936000000 4% /var/lib/docker/overlay2/abc/merged
EOF
# shellcheck disable=SC1090
mounts=$(. "$MOUNTLIB"; scan_mounts_parse < "$TMP/df.out")
n_mounts=$(printf '%s\n' "$mounts" | grep -c .)
if [ "$n_mounts" -eq 3 ]; then
  ok "mount scan drops pseudo, snapshot and container filesystems (3 of 9 kept)"
else
  bad "mount scan kept $n_mounts entries, expected 3: $(printf '%s' "$mounts" | tr '\n' ' ')"
fi

# A mount point with a space is an ordinary name; taking a single df field
# truncates it silently, which is constraint 18 wearing a different hat.
printf '%s\n' "$mounts" | grep -q "^/Volumes/My Backup Drive	" \
  && ok "mount scan keeps a mount point containing a space intact" \
  || bad "mount point with a space was truncated"

# External drives must sort above the system disk: on a backup tool that is
# what the operator is reaching for, and putting / first invites a mis-click.
first=$(printf '%s\n' "$mounts" | head -1 | cut -f1)
case "$first" in
  /Volumes/*|/mnt/*) ok "mount scan lists external drives before the system disk" ;;
  *) bad "system disk sorted first: $first" ;;
esac

# Numeric choice resolves to a path; anything else passes through untouched, so
# typing a path the scan never saw always still works.
# shellcheck disable=SC1090
sel=$(. "$MOUNTLIB"
      printf '%s\n' "$mounts" | render_mount_menu "$TMP/midx" >/dev/null
      resolve_mount_choice "$TMP/midx" 1)
# shellcheck disable=SC1090
typed=$(. "$MOUNTLIB"; resolve_mount_choice "$TMP/midx" /some/unlisted/path)
if [ "$sel" = "/Volumes/My Backup Drive" ] && [ "$typed" = "/some/unlisted/path" ]; then
  ok "mount choice resolves a number, and passes a typed path through"
else
  bad "choice resolution wrong (number->'$sel', typed->'$typed')"
fi

# --- 31: the watchdog must give up and escalate, not loop --------------------
# With no backoff it restarted a failing job every 15 minutes for three hours --
# twelve attempts against a full volume -- and the repeated "repair" made the
# outage look handled. Exercise the real helpers rather than reimplementing them.
mkdir -p "$TMP/wdstate"
wd_helpers=$(awk '/^MAX_REPAIR_ATTEMPTS=/,/^should_attempt\(\)/' "$WATCHDOG")
if [ -z "$wd_helpers" ]; then
  bad "watchdog has no repair-backoff helpers at all"
else
  res=$(STATE="$TMP/wdstate" bash -c "
    $wd_helpers
    n=0
    for i in 1 2 3 4 5 6; do should_attempt t && { fail_bump t; n=\$((n+1)); }; done
    echo -n \"attempts=\$n\"
    fail_reset t
    should_attempt t && echo ' reset=ok' || echo ' reset=BROKEN'
  " 2>/dev/null)
  case "$res" in
    "attempts=3 reset=ok") ok "watchdog stops after 3 failed repairs and resets on recovery" ;;
    *) bad "backoff wrong: $res (expected attempts=3 reset=ok)" ;;
  esac
fi

# Every repair call must be gated. An ungated one reintroduces the loop on a
# path nobody is looking at -- which is exactly how the no-snapshots branch
# kept retrying forever after the stale branch had been fixed.
# Count both sides. The original version computed `ungated` and then never
# looked at it, asserting only that two gated calls exist -- so adding a THIRD,
# ungated trigger would have left this green. Which is the precise shape of the
# bug it was written for.
gated=$(grep -c 'should_attempt "stale.\$h"' "$WATCHDOG")
triggers=$(grep -c 'run-backup \$h' "$WATCHDOG")
if [ "$gated" -ge 2 ] && [ "$triggers" -le "$gated" ]; then
  ok "both trigger paths (no-snapshots and stale) are backoff-gated"
else
  bad "$triggers trigger call(s) but only $gated gate(s) — one can still loop"
fi

# --- 32: ssh inside a `while read` loop eats the loop's stdin ----------------
# One triggered repair consumed the rest of the host list and every remaining
# host was silently skipped -- they just vanished from the report. -n fixes all
# call sites at once.
if grep -q 'SSH="ssh -n ' "$WATCHDOG"; then
  ok "watchdog ssh uses -n so a repair cannot swallow the host list"
else
  bad "watchdog ssh lacks -n — a repair inside a read-loop will skip hosts"
fi

# --- 23: one definition of safe_token -----------------------------------------
# The forced-command dispatcher is deliberately self-contained, so it carries
# its own copy. A copy that drifts from the writer's validator is exactly how a
# fix landed in one agent and never reached the other.
extract(){ awk -v f="$2" '$0 ~ "^" f "\\(\\)\\{", /^\}/' "$1"; }
for fn in safe_token safe_arg; do
  a=$(extract "$LIB" "$fn"); b=$(extract "$REMOTE" "$fn")
  if [ -n "$a" ] && [ "$a" = "$b" ]; then
    ok "$fn is identical in lib-validate.sh and the dispatcher"
  else
    bad "$fn has diverged between lib-validate.sh and the dispatcher"
  fi
done

# epoch_of is duplicated across the engine, status and lib-validate because none
# of them source each other at runtime. That duplication is tolerable only while
# the copies are identical -- and they were not: a FOURTH copy was written into
# the watchdog with the GNU branch only, so on a macOS watchdog every timestamp
# parsed to 0, every host was skipped, and the run reported "all clear" having
# checked nothing. Constraints 28 and 36, reintroduced inside their enforcer.
EPOCH_FILES="$LIB $ENGINE $ROOT/agents/common/snapfabric-status.sh"
canon=""; drifted=""
for f in $EPOCH_FILES; do
  body=$(extract "$f" epoch_of)
  [ -n "$body" ] || { drifted="$drifted $(basename "$f"):missing"; continue; }
  [ -z "$canon" ] && canon="$body"
  [ "$body" = "$canon" ] || drifted="$drifted $(basename "$f")"
done
[ -z "$drifted" ] && ok "epoch_of is identical in every copy" \
                  || bad "epoch_of has drifted:$drifted"

# Any copy that parses only one platform's date format is the original bug.
for f in $EPOCH_FILES "$ROOT/agents/common/snapfabric-doctor.sh"; do
  if grep -q 'date -d' "$f" && ! grep -q 'date -j -f' "$f"; then
    bad "$(basename "$f") parses timestamps with GNU date only — silently skips every host on macOS"
  fi
done
ok "no script parses snapshot timestamps with only one platform's date"

# --- 24: plan mutates nothing outside its output directory --------------------
# "Nothing is touched until the operator has seen the plan" is the whole point
# of the phase ordering, so it gets a test rather than a comment.
if [ -e "/Volumes/NotPresentHere" ]; then
  bad "plan created the backup root it was only supposed to record"
else
  ok "plan creates nothing on the backup drive"
fi

# --- 34: the size gate ---------------------------------------------------------
# Exercises the gate text lifted verbatim out of the engine, with du/df/ln
# stubbed. Extracting the real block rather than restating the logic is
# deliberate: a test that reimplements the rule passes while the shipped code
# rots (constraint 21).
sed -n '/^# --- size gate/,/^# --- retention/p' "$ENGINE" | sed '$d' > "$TMP/gate.sh"
[ -s "$TMP/gate.sh" ] || bad "could not extract the size gate from the engine"

gate(){ # gate <sizes-file-contents> <new-size-k> [env assignments...]
  local sizes="$1" newk="$2"; shift 2
  # printf '%s\\n', not '%s': without the trailing newline an appended entry
  # concatenates onto the last one (49300000030000000) and the fixture stops
  # representing what the script actually writes.
  mkdir -p "$TMP/g/host"; printf '%s\\n' "$sizes" > "$TMP/g/host/.accepted-sizes"
  [ -n "$sizes" ] || rm -f "$TMP/g/host/.accepted-sizes"
  {
    echo 'HOST_DIR="'"$TMP"'/g/host"; NEW="$HOST_DIR/2026-01-01_000000"; PREV="'"${PREVDIR:-}"'"'
    echo 'LINKED=0'
    echo 'log(){ echo "LOG: $*"; }'
    echo 'die(){ echo "DIE: $*"; exit 9; }'
    # du must tell the new snapshot apart from the previous one, or the
    # bootstrap floor (which compares the two) cannot be exercised at all.
    echo 'du(){ case "$*" in *"'"${PREVDIR:-__nomatch__}"'"*) echo "'"${PREVK:-0}"'	prev";; *) echo "'"$newk"'	target";; esac; }'
    echo 'df(){ printf "h\n/dev/x 1 1 1 '"${FULLPCT:-40}"'%% /\n"; }'
    echo 'ln(){ echo LINKED; }'
    echo 'mv(){ :; }'
    echo 'tail(){ :; }'
    cat "$TMP/gate.sh"
  } > "$TMP/g/run.sh"
  env "$@" bash "$TMP/g/run.sh" 2>&1
}

good_hist=$(printf '494000000\n493000000')
poisoned=$(printf '494000000\n493000000\n30000')   # the stub was blessed most recently

echo "$(gate "$good_hist" 0)" | grep -q LINKED \
  && bad "a zero-byte snapshot was blessed as 'latest'" \
  || ok "a zero-byte snapshot is refused, 'latest' untouched"

# The case that a previous-snapshot comparison cannot catch: history already
# contains a blessed 29MB stub, so the predecessor is useless as a baseline.
echo "$(gate "$poisoned" 62914560)" | grep -q LINKED \
  && bad "a 13%-of-high-water snapshot was blessed (baseline poisoned by a stub)" \
  || ok "the high-water mark refuses a truncated run despite a stub in history"

echo "$(gate "$good_hist" 503316480)" | grep -q LINKED \
  && ok "a healthy snapshot is still blessed normally" \
  || bad "the gate blocked a healthy snapshot"

echo "$(gate "" 503316480)" | grep -q LINKED \
  && ok "the first run establishes the baseline instead of blocking" \
  || bad "the gate blocked the very first run"

echo "$(gate "$good_hist" 62914560 ALLOW_SHRINK=1)" | grep -q LINKED \
  && ok "ALLOW_SHRINK=1 overrides the gate for a genuine deletion" \
  || bad "ALLOW_SHRINK=1 did not override the gate"

# Measure-before-bless is an ORDERING property; a test that only exercises the
# extracted gate block cannot see the symlink being moved back above it.
gate_ln=$(grep -n '^# --- size gate' "$ENGINE" | cut -d: -f1)
bless_ln=$(grep -n 'ln -sfn "\$NEW" "\$LATEST"' "$ENGINE" | cut -d: -f1)
if [ -n "$gate_ln" ] && [ -n "$bless_ln" ] && [ "$bless_ln" -gt "$gate_ln" ] 2>/dev/null; then
  ok "'latest' is moved only after the size gate has run"
else
  bad "'latest' is blessed before the size gate (gate line ${gate_ln:-?}, bless line ${bless_ln:-?})"
fi

# The bootstrap case: with no high-water mark there is nothing to compare
# against, so a thin run would become the reference and leave the gate inert --
# which is exactly how a stub history accumulates.
# The engine records by appending to .accepted-sizes directly, not through any
# stubbed command, so read the file rather than watching for a marker -- an
# earlier version of this test grepped for output that the engine never emits
# and "passed" without exercising anything.
PREVDIR="/prev"; PREVK=494000000; export PREVDIR PREVK
thin_out=$(gate "" 62914560)
if [ -s "$TMP/g/host/.accepted-sizes" ]; then
  bad "a thin run established the gate baseline (the gate is now inert)"
else
  ok "a thin run is refused as the FIRST baseline"
fi
# ...and refusing to RECORD it is not enough. Declining the baseline while still
# advancing 'latest' is incoherent, and it happened in real use: a
# complete snapshot was replaced as 'latest' by one 43% of its size because no
# baseline existed yet. Fit-to-be-a-reference and fit-to-be-the-restore-point
# are the same question.
if printf '%s' "$thin_out" | grep -q "^LINKED$"; then
  bad "a thin run was blessed as 'latest' even though it was refused as a baseline"
else
  ok "a thin run is refused as 'latest' too, not just as the baseline"
fi
gate "" 480000000 >/dev/null
if grep -q '^480000000$' "$TMP/g/host/.accepted-sizes" 2>/dev/null; then
  ok "a healthy run does establish the first baseline"
else
  bad "a healthy run was refused as the first baseline"
fi
unset PREVDIR PREVK

# ALLOW_SHRINK must RESET the scale, not append to it.
#
# The gate takes the MAX of the last five accepted sizes, and a REFUSED run
# records nothing. So appending after an override leaves the old large entries
# in place with nothing able to rotate them out: the very next run is measured
# against them and refused again, forever. On a real estate that deadlocked
# a laptop's backups for 28 days after a deliberate, permanent scope reduction --
# one override accepted, every run after it refused against four stale entries.
PREVDIR=""; PREVK=""
printf '494000000\n493000000\n' > "$TMP/g/host/.accepted-sizes"
gate "$(printf '494000000\n493000000')" 30000000 ALLOW_SHRINK=1 >/dev/null
left=$(grep -c . "$TMP/g/host/.accepted-sizes" 2>/dev/null || echo 0)
big=$(awk '$1 > 100000000' "$TMP/g/host/.accepted-sizes" 2>/dev/null | grep -c . || true)
if [ "$left" = "1" ] && [ "${big:-0}" = "0" ]; then
  ok "ALLOW_SHRINK resets the baseline instead of appending to it"
else
  bad "ALLOW_SHRINK left $left entries (${big:-0} stale large) — the gate will deadlock"
fi
# And the proof that matters: the NEXT ordinary run must now pass.
out=$(gate "$(cat "$TMP/g/host/.accepted-sizes")" 30000000)
printf '%s' "$out" | grep -q "^LINKED$" \
  && ok "after ALLOW_SHRINK, the next ordinary run at the new scale is accepted" \
  || bad "still refused after ALLOW_SHRINK — the 28-day deadlock is back"

# A refused run must not leave its directory behind (constraint 7: retention
# runs on the failure path too). Refusals skip the retention block entirely, so
# without this every rejected snapshot accumulates -- 500 of them in 28 days on
# one estate. Only directories NEWER than 'latest' may be pruned: everything at
# or older than it is real history, and an over-broad rule deleted a valid
# day-old snapshot the first time it actually ran.
PRUNE="$TMP/prune/host"; mkdir -p "$PRUNE"
for d in 2026-01-01_000000 2026-01-02_000000 2026-01-03_000000 2026-01-04_000000; do mkdir -p "$PRUNE/$d"; done
ln -sfn "$PRUNE/2026-01-02_000000" "$PRUNE/latest"
(
  # shellcheck disable=SC2034  # read by the eval'd prune_unblessed
  HOST_DIR="$PRUNE"
  # shellcheck disable=SC2034
  LATEST="$PRUNE/latest"
  log(){ :; }
  eval "$(sed -n '/^prune_unblessed(){/,/^}/p' "$ENGINE")"
  prune_unblessed
)
# shellcheck disable=SC2010  # fixture names are fixed timestamps
left=$(ls -1 "$PRUNE" | grep '^[0-9]' | sort | tr '\n' ' ')
# keeps: 01 and 02 (history, at/older than latest) and 04 (newest = resume base)
if [ "$left" = "2026-01-01_000000 2026-01-02_000000 2026-01-04_000000 " ]; then
  ok "refusal pruning removes unblessed dirs and spares history"
else
  bad "prune_unblessed wrong: left [$left]"
fi

# --- 35: date patterns must not be anchored on a specific year ------------------
if grep -rn "\^20[0-9][0-9]-" "$ROOT/agents" >/dev/null 2>&1; then
  bad "a snapshot pattern is anchored on a hardcoded year (breaks on 1 January)"
else
  ok "no snapshot pattern is anchored on a hardcoded year"
fi

# --- add-node: adding one host must not disturb the others ----------------------
# The whole risk of add-node is the merge. plan rewrites the config wholesale;
# add-node edits a live one whose other hosts have running schedulers named
# after settings in it. This builds a three-host fabric, adds a fourth, and
# asserts that every byte concerning the first three survived.
ADDNODE="$ROOT/agents/common/snapfabric-addnode.sh"
AN="$TMP/an"; mkdir -p "$AN/hosts"
cat > "$AN/snapfabric.conf" <<'EOF'
# snapfabric configuration
HUB_USER="op"
HUB_HOST="hub.example"
HUB_KEY="$HOME/.ssh/snapfabric_hub"
BACKUP_ROOT="/Volumes/Backup Drive"
MANAGED_VOLUMES="Backup Drive"
BACKUP_HOSTS="fileserver workstation nas"
PUSH_HOSTS="workstation"
FRESHNESS="fileserver:30 workstation:30 nas:210"
PULL_LABEL_PREFIX="org.example.snap"
REMOTE_CMD="~/bin/snapfabric-remote"
BWLIMIT=4000
KEEP_HOURLY=24
KEEP_DAILY=30
KEEP_WEEKLY=8
KEEP_MONTHLY=12
ADVERTISER_PATTERN=""
ADVERTISER_LABEL=""
WATCHDOG_HOST=""
WATCHDOG_KEY=""
EOF
cp "$AN/snapfabric.conf" "$TMP/an.before"

# tag, ssh user, address, port, push?, scan?, source, (blank), exclude 'default',
# (blank), schedule, write?
"$ADDNODE" --conf "$AN" --no-provision --plain >"$TMP/an.out" 2>&1 <<'EOF'
buildbox
ci
buildbox.example
22
n
n
/srv/ci data
default

daily
y
EOF
an_rc=$?

if [ "$an_rc" -ne 0 ]; then
  bad "add-node exited $an_rc"
  sed 's/^/        /' "$TMP/an.out" | tail -5
else
  ok "add-node completed against an existing fabric"
fi

# 1. every hub-level setting that is not one of the three lists is untouched
diff_out=$(diff "$TMP/an.before" "$AN/snapfabric.conf" | grep '^[<>]' | grep -vE 'BACKUP_HOSTS|PUSH_HOSTS|FRESHNESS')
if [ -z "$diff_out" ]; then
  ok "add-node changed only the three host lists in the hub config"
else
  bad "add-node altered hub-level settings it should not have touched"
  printf '%s\n' "$diff_out" | sed 's/^/        /'
fi

# 2. the existing hosts keep their freshness limits
. "$AN/snapfabric.conf"
miss=""
for pair in fileserver:30 workstation:30 nas:210; do
  case " $FRESHNESS " in *" $pair "*) ;; *) miss="$miss $pair" ;; esac
done
[ -z "$miss" ] && ok "existing hosts keep their staleness limits" \
               || bad "add-node dropped freshness for:$miss  (FRESHNESS=$FRESHNESS)"

# 3. the new host is present in all three lists, exactly once, and push is intact
[ "$BACKUP_HOSTS" = "fileserver workstation nas buildbox" ] \
  && ok "the new host is appended to BACKUP_HOSTS without reordering the rest" \
  || bad "BACKUP_HOSTS is wrong: $BACKUP_HOSTS"
[ "$PUSH_HOSTS" = "workstation" ] \
  && ok "a pull host is not added to PUSH_HOSTS" \
  || bad "PUSH_HOSTS is wrong: $PUSH_HOSTS"

# 4. the host config exists, and a source containing a space survived intact
if [ -r "$AN/hosts/buildbox.conf" ]; then
  ok "add-node wrote hosts/buildbox.conf"
  SOURCES=""; . "$AN/hosts/buildbox.conf"
  n_src=$(printf '%s' "$SOURCES" | grep -c .)
  [ "$n_src" = "1" ] && [ "$SOURCES" = "/srv/ci data" ] \
    && ok "a source path containing a space survived add-node intact" \
    || bad "source mangled by add-node: [$SOURCES] ($n_src lines)"
else
  bad "add-node did not write hosts/buildbox.conf"
fi

# 5. a duplicate tag is refused rather than appended
"$ADDNODE" --conf "$AN" --no-provision --plain >"$TMP/dup.out" 2>&1 <<'EOF'
nas
EOF
grep -q "already in the fabric" "$TMP/dup.out" \
  && ok "add-node refuses a tag that is already in the fabric" \
  || bad "add-node did not refuse a duplicate tag"

# add-node must survive a config directory whose name contains a space, and
# must hand that path to provision as ONE argument. macOS puts application data
# under "Application Support"; this is not an exotic case.
AN2="$TMP/conf dir with spaces"; mkdir -p "$AN2/hosts"
sed 's|^BACKUP_HOSTS=.*|BACKUP_HOSTS="fileserver"|; s|^FRESHNESS=.*|FRESHNESS="fileserver:30"|; s|^PUSH_HOSTS=.*|PUSH_HOSTS=""|' \
  "$TMP/an.before" > "$AN2/snapfabric.conf"
"$ADDNODE" --conf "$AN2" --no-provision --plain >"$TMP/an2.out" 2>&1 <<'EOF'
spacebox
ci
spacebox.example
22
n
n
/srv/data
default

daily
y
EOF
if [ -r "$AN2/hosts/spacebox.conf" ]; then
  ok "add-node works with a config directory containing a space"
else
  bad "add-node failed against a config path with a space"
  tail -3 "$TMP/an2.out" | sed 's/^/        /'
fi

# The provision hand-off itself: a space-joined argument string would arrive as
# four arguments. Stand in a fake provision that records its argv and count it.
FAKEP="$TMP/fakeprov"; mkdir -p "$FAKEP"
cp "$ROOT/agents/common/snapfabric-addnode.sh" "$FAKEP/snapfabric-addnode.sh"
for f in lib-validate.sh lib-mounts.sh lib-host.sh; do cp "$ROOT/agents/common/$f" "$FAKEP/$f"; done
cat > "$FAKEP/snapfabric-provision.sh" <<'FAKE'
#!/bin/bash
printf '%s\n' "$#" > "$ARGC_OUT"
for a in "$@"; do printf '[%s]\n' "$a" >> "$ARGC_OUT"; done
exit 0
FAKE
chmod 755 "$FAKEP/snapfabric-provision.sh"
AN3="$TMP/another dir"; mkdir -p "$AN3/hosts"
cp "$AN2/snapfabric.conf" "$AN3/snapfabric.conf"
ARGC_OUT="$TMP/argv.txt" "$FAKEP/snapfabric-addnode.sh" --conf "$AN3" --plain >"$TMP/an3.out" 2>&1 <<'EOF'
argbox
ci
argbox.example
2222
n
n
/srv/data
default

daily
y
y
EOF
if [ -r "$TMP/argv.txt" ]; then
  argc=$(head -1 "$TMP/argv.txt")
  # --conf <dir> --host <tag> --plain = 5. The discriminating assertion is the
  # second one: the spaced path must arrive as a single argument, not three.
  if [ "$argc" = "5" ] && grep -qxF "[$AN3]" "$TMP/argv.txt"; then
    ok "add-node passes a spaced --conf to provision as one argument"
  else
    bad "add-node split its provision arguments (argc=$argc, wanted 5)"
    sed 's/^/        /' "$TMP/argv.txt"
  fi
else
  bad "add-node never invoked provision"
  tail -3 "$TMP/an3.out" | sed 's/^/        /'
fi

# The ssh port must survive into the generated config. It was hardcoded to 22
# and never asked, so a host on another port failed as a bare `rsync exited 255`
# -- an ssh error wearing a transfer error's clothes, which is constraint 24 and
# which the engine was already fixed for.
if [ -r "$AN3/hosts/argbox.conf" ]; then
  SSH_PORT=""; . "$AN3/hosts/argbox.conf"
  [ "$SSH_PORT" = "2222" ] && ok "a non-default ssh port reaches the generated host config" \
                           || bad "ssh port not carried through: SSH_PORT=$SSH_PORT (wanted 2222)"
else
  bad "no host config written for the port test"
fi

# --- launchd domain: provision and the verb API must agree ----------------------
# provision installs a USER LaunchAgent and bootstraps gui/<uid>; the verb API
# asked launchd about system/<label> and looked for /Library/LaunchDaemons.
# Nothing reconciled them, so every scheduler reported `missing` -- a permanent
# NEEDS ATTENTION on a healthy hub -- and every repair and trigger aimed at a
# domain the job was not in, which the watchdog then retried until it escalated.
if grep -q 'LaunchAgents' "$ROOT/agents/common/snapfabric-provision.sh"; then
  if grep -q 'LaunchAgents' "$REMOTE"; then
    ok "the verb API knows about the domain provision actually installs into"
  else
    bad "provision installs a LaunchAgent but the verb API never looks in that domain"
  fi
else
  ok "provision does not use LaunchAgents (domain check not applicable)"
fi
# It must not go looking in only one domain.
if grep -q 'sf_domain' "$REMOTE" && grep -q 'gui/\$(id -u)' "$REMOTE"; then
  ok "the verb API resolves the launchd domain instead of assuming one"
else
  bad "the verb API assumes a single launchd domain"
fi
# And a user agent must be restarted WITHOUT sudo -- requiring it for every job
# means a hub whose account has no passwordless sudo cannot be repaired at all,
# and it is a privilege this key should never need. Assert the unprivileged path
# exists rather than grepping a fixed window: the first version of this check
# used -A6, missed the line it was looking for, and passed via its else branch.
if grep -q 'kickstart -k "\$dom/\$l"' "$REMOTE"; then
  ok "a user agent is restarted without sudo"
else
  bad "restart-service has no unprivileged path — every repair demands sudo"
fi
if grep -q 'sudo /bin/launchctl kickstart -k "system/\$l"' "$REMOTE"; then
  ok "a system daemon still gets sudo where it genuinely needs it"
else
  bad "restart-service lost the privileged path for system daemons"
fi

# SVC lines gained a domain field; every reader must expect it or it silently
# absorbs "loaded|gui/501" into the status field and reports healthy jobs down.
for f in "$ROOT/agents/common/snapfabric-status.sh" "$ROOT/agents/common/snapfabric-doctor.sh"; do
  if grep -q "SVC" "$f"; then
    grep -q 'read -r .*st dom' "$f" \
      && ok "$(basename "$f") reads the SVC domain field" \
      || bad "$(basename "$f") would absorb the SVC domain field into the status"
  fi
done

# --- scratch files must not be predictable -------------------------------------
# doctor wrote /tmp/.sfvol.$$ and friends. $$ is guessable and /tmp is
# world-writable; the sticky bit stops deletion, not a pre-created symlink
# redirecting the write. Every other script already used mktemp -d, and doctor
# is the one the docs tell you to run from cron every fifteen minutes.
bad_tmp=""
for f in "$ROOT"/agents/common/*.sh "$ROOT"/agents/macos/*.sh "$ROOT"/bin/snapfabric; do
  grep -qE '(>|<) */tmp/[^ ]*\$\$' "$f" 2>/dev/null && bad_tmp="$bad_tmp $(basename "$f")"
done
[ -z "$bad_tmp" ] && ok "no script writes to a predictable /tmp path" \
                  || bad "predictable /tmp scratch files in:$bad_tmp"

# --- generated schedulers must quote their arguments ----------------------------
# The plist <string> is ONE ssh command re-split by the remote shell; systemd
# splits ExecStart on whitespace; cron lines are shell. All three were built by
# interpolating $BIN_DIR and $HCONF bare, so a config directory containing a
# space (~/Library/Application Support is the obvious one) produced a scheduler
# that ran and failed every night. Constraints 18 and 30, one layer below the
# test that already asserts add-node hands provision a spaced path intact.
PROVSH="$ROOT/agents/common/snapfabric-provision.sh"
unquoted=""
grep -q "<string>'\$BIN_DIR/snapshot-engine.sh' '\$HCONF'</string>" "$PROVSH" || unquoted="$unquoted launchd"
grep -q 'ExecStart="\$BIN_DIR/snapshot-engine.sh" "\$HCONF"' "$PROVSH"       || unquoted="$unquoted systemd"
grep -q '\\047%s\\047 \\047%s\\047' "$PROVSH"                              || unquoted="$unquoted cron"
[ -z "$unquoted" ] && ok "launchd, systemd and cron all quote the paths they are given" \
                   || bad "scheduler arguments are unquoted for:$unquoted"

# And the quoting must actually render as quotes -- writing '%s' inside a
# single-quoted printf format ends the shell quote and emits nothing, which is
# exactly what the first attempt at this fix did.
rendered=$(BIN_DIR=/b HCONF="/a b/c.conf" OFFSET_MIN=7 bash -c \
  'printf "%d * * * * \047%s\047 \047%s\047 %s\n" "$OFFSET_MIN" "$BIN_DIR/e.sh" "$HCONF" "#tag"')
case "$rendered" in
  *"'/a b/c.conf'"*) ok "a cron line renders its config path inside real quotes" ;;
  *)                 bad "cron quoting does not render as quotes: $rendered" ;;
esac

# --- the Linux path must not touch the operator's real machine during tests ------
# SNAPFABRIC_NO_ACTIVATE was checked inside the systemd branch only, so on a
# systemd-less box (a container, most CI images) the suite fell through to cron
# and installed an entry into the REAL crontab -- the exact thing the README and
# the suite header both promise never happens. And there was no
# SNAPFABRIC_SYSTEMD_DIR to match SNAPFABRIC_LAUNCHD_DIR, so unit files landed
# in the operator's home too.
if grep -q 'SYSTEMD_DIR="\${SNAPFABRIC_SYSTEMD_DIR:-' "$PROVSH"; then
  ok "the systemd unit directory is overridable, like the launchd one"
else
  bad "no SNAPFABRIC_SYSTEMD_DIR override — tests write units into the real home"
fi
# The cron fallback must be gated. Check the gate appears before the crontab
# call within the fallback branch.
cron_ln=$(grep -n '| crontab -' "$PROVSH" | head -1 | cut -d: -f1)
gate_ln=$(grep -n 'not installing a crontab entry' "$PROVSH" | head -1 | cut -d: -f1)
if [ -n "$cron_ln" ] && [ -n "$gate_ln" ] && [ "$gate_ln" -lt "$cron_ln" ] 2>/dev/null; then
  ok "SNAPFABRIC_NO_ACTIVATE gates the cron fallback, not just systemd"
else
  bad "the cron fallback is ungated — a test run would edit the real crontab"
fi
# A --user timer that is enabled but not lingering never fires on a headless
# hub. Reporting it as scheduled is the silent-success failure mode again.
# Match the actual query, not the word: the first version of this check grepped
# for "Linger" and was satisfied by its own explanatory comment.
grep -q 'loginctl show-user .* -p Linger --value' "$PROVSH" \
  && ok "provision checks user lingering before calling a Linux timer scheduled" \
  || bad "provision reports a --user timer scheduled without checking lingering"

# --- a key check must offer only the key it is checking ------------------------
# provision proves each key is restricted by trying to get a shell with it. That
# proves nothing unless ssh offers ONLY that key: with an agent loaded, or with
# the operator's default identity accepted on the host, the shell comes back
# through a different credential entirely. The check then refuses a correctly
# restricted host -- or, worse, credits a key with a restriction it does not
# have. Found by making the test suite hermetic: once it used an agent instead
# of borrowing the developer's key, every restriction check inverted.
if grep -q 'VOPTS="\$SSH_OPTS -o IdentitiesOnly=yes"' "$PROVSH"; then
  ok "provision defines an identity-isolated option set for verification"
else
  bad "provision has no IdentitiesOnly option set — restriction checks are unreliable"
fi
leaky=$(grep -c 'ssh -i \$SSH_KEY \$SSH_OPTS' "$PROVSH" || true)
[ "$leaky" = "0" ] && ok "no restriction check runs without IdentitiesOnly" \
                   || bad "$leaky restriction check(s) still offer other identities"
# The bootstrap must NOT be identity-isolated: its entire job is to get in with
# whatever other credential already works.
if grep -q 'BOOTSTRAP="ssh \$SSH_OPTS' "$PROVSH"; then
  ok "bootstrap still accepts other credentials, as it must"
else
  bad "bootstrap no longer uses the permissive option set — first-time setup will fail"
fi
# The engine and verify should authenticate as the backup key and nothing else.
for f in "$ENGINE" "$ROOT/agents/common/snapfabric-verify.sh"; do
  grep -q 'IdentitiesOnly=yes' "$f" \
    && ok "$(basename "$f") authenticates with the backup key only" \
    || bad "$(basename "$f") could authenticate with an unrelated agent key"
done

# --- the documented test-coverage claim must be true ----------------------------
# README used to say every constraint had a test; about half did not. A claim
# about coverage rots the instant someone adds a rule, so it is checked here:
# each constraint's "Tested:" marker must agree with whether the suites actually
# cite it by number, and the headline count must match.
DOC="$ROOT/docs/CONSTRAINTS.md"
cited=$(grep -hoE '^# --- [0-9]+:' "$ROOT/tests/test-constraints.sh" | grep -oE '[0-9]+'
        grep -hoiE 'constraints? [0-9]+( and [0-9]+)?' "$ROOT/tests"/*.sh | grep -oE '[0-9]+')
cited=$(printf '%s\n' "$cited" | sort -n | uniq)
mismatch=""
for n in $(grep -oE '^## [0-9]+\.' "$DOC" | grep -oE '[0-9]+'); do
  marker=$(awk -v want="## $n." '
    index($0, want) == 1 { found=1; next }
    found && /^\*\*Tested:\*\*/ { print; exit }' "$DOC")
  case "$marker" in
    *"yes"*) is_marked=1 ;;
    *)       is_marked=0 ;;
  esac
  if printf '%s\n' "$cited" | grep -qx "$n"; then is_cited=1; else is_cited=0; fi
  [ "$is_marked" = "$is_cited" ] || mismatch="$mismatch $n"
done
[ -z "$mismatch" ] && ok "every constraint's Tested: marker matches whether a test cites it" \
                   || bad "Tested: marker disagrees with the suites for constraint(s):$mismatch"

claimed=$(grep -oE '\*\*[0-9]+ of [0-9]+\*\*' "$DOC" | head -1 | grep -oE '[0-9]+' | head -1)
actual=$(grep -c '^\*\*Tested:\*\* yes' "$DOC")
[ "$claimed" = "$actual" ] && ok "the coverage figure in CONSTRAINTS.md is accurate ($actual)" \
                           || bad "CONSTRAINTS.md claims $claimed tested, actually $actual"

# --- file modes must follow one convention -------------------------------------
# Libraries are sourced and should not be executable; everything else is an entry
# point and should be. This was inconsistent -- two scripts that get executed
# were 0644 while a sourced library was 0755 -- which is harmless here only
# because the dispatcher runs everything through `bash`. It stops being harmless
# the moment someone runs one directly, or packages the tree.
# git is the one external dependency in this otherwise offline suite. If it
# returns nothing -- index locked, not a checkout, git missing -- the loop below
# reads zero lines, mode_bad stays empty, and this reports PASS having checked
# nothing. Count first and fail loudly instead.
mode_listing=$(cd "$ROOT" && git ls-files -s -- '*.sh' bin/snapfabric install.sh 2>/dev/null)
mode_n=$(printf '%s\n' "$mode_listing" | grep -c .)
if [ "${mode_n:-0}" -lt 10 ]; then
  bad "file-mode check could not list files via git (got ${mode_n:-0}) — not verified"
fi
mode_bad=""
while read -r mode _ _ path; do
  # git ls-files below already restricts this to scripts and entry points, so
  # anything that is not a library must be executable. (An explicit
  # install.sh branch after *.sh would be dead code -- shellcheck SC2222.)
  case "$path" in
    */lib-*.sh) [ "$mode" = "100644" ] || mode_bad="$mode_bad $path(should-be-644)" ;;
    *)          [ "$mode" = "100755" ] || mode_bad="$mode_bad $path(should-be-755)" ;;
  esac
done <<EOF
$mode_listing
EOF
if [ -z "$mode_bad" ]; then
  ok "libraries are 0644 and executables are 0755"
else
  bad "file modes inconsistent:$mode_bad"
fi

# --- dispatcher: must resolve agents/ through a symlink install -------------------
# This is the failure that works perfectly in a git checkout and breaks for
# everyone who installs it: `readlink -f` does not exist on macOS, so a naive
# dispatcher finds agents/ next to the symlink in ~/.local/bin instead of next
# to the real script.
DISP="$ROOT/bin/snapfabric"
if [ -x "$DISP" ]; then
  ok "bin/snapfabric is executable"
  "$DISP" version >/dev/null 2>&1 && ok "dispatcher runs from the checkout" \
                                  || bad "dispatcher failed in the checkout"
  mkdir -p "$TMP/fakebin"
  ln -sfn "$DISP" "$TMP/fakebin/snapfabric"
  if "$TMP/fakebin/snapfabric" version >/dev/null 2>&1; then
    ok "dispatcher resolves agents/ through a symlink install"
  else
    bad "dispatcher cannot find agents/ when invoked through a symlink"
  fi
  # An unknown command must not become a path to execute.
  "$DISP" ../../../bin/sh >/dev/null 2>&1
  [ $? -eq 2 ] && ok "dispatcher refuses an argument that looks like a path" \
               || bad "dispatcher did something with a path-shaped command"
  # Every command it advertises must actually exist, and `help` must be inert.
  # This assertion used to pass by making a live network call: `help status`
  # read the operator's real config and queried the real hub, so it reported
  # "implemented" only while that hub happened to be healthy. Point the config
  # at an empty directory -- help must still work with nothing configured.
  missing=""; noisy=""
  for c in discover plan add-node provision verify status doctor; do
    SNAPFABRIC_CONF_DIR="$TMP/nonexistent-conf" \
    SNAPFABRIC_CONF="$TMP/nonexistent-conf/snapfabric.conf" \
      "$DISP" help "$c" >"$TMP/help.$c" 2>&1 || missing="$missing $c"
    grep -qi "no config\|unreachable\|CRITICAL" "$TMP/help.$c" 2>/dev/null && noisy="$noisy $c"
  done
  [ -z "$missing" ] && ok "every advertised command has an implementation" \
                    || bad "advertised but missing:$missing"
  [ -z "$noisy" ] && ok "help works with nothing configured and contacts nothing" \
                  || bad "help needs a live config or hub for:$noisy"
else
  bad "bin/snapfabric is missing or not executable"
fi

echo
printf "  %d passed, %d failed\n\n" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
