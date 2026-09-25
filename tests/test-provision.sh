#!/bin/bash
# Integration test for `snapfabric provision`.
#
#   usage: tests/test-provision.sh
#
# Stands up a throwaway sshd as the current user on a high port, provisions
# against it, and tears it down. Everything lives in one temp directory: no
# sudo, no system settings, no change to the real ~/.ssh/authorized_keys, and
# no host on your network is contacted.
#
# This exists because the offline tests cannot catch what only appears against a
# real SSH server. The first run of it found that the snapshot engine hardcoded
# port 22 -- every host not on 22 would have failed with a bare "rsync exited
# 255", an ssh-level error reported as a transfer failure.
#
# If sshd cannot be started the tests are SKIPPED, and skipped is reported
# separately from passed. A suite that silently reports "all green" when it
# tested nothing is worse than one that fails.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROV="$ROOT/agents/common/snapfabric-provision.sh"
ENGINE="$ROOT/agents/common/snapshot-engine.sh"
T=$(mktemp -d); chmod 700 "$T"
pass=0; fail=0; skip=0

ok(){   printf "  \033[32mPASS\033[0m  %s\n" "$1"; pass=$((pass+1)); }
bad(){  printf "  \033[31mFAIL\033[0m  %s\n" "$1"; fail=$((fail+1)); }
skipm(){ printf "  \033[33mSKIP\033[0m  %s\n" "$1"; skip=$((skip+1)); }

# Kill by config path as well as by pidfile. An early exit can happen in the
# window between sshd forking and writing its pidfile, and the orphan then holds
# the port with an authorized_keys file that no longer exists -- so the NEXT run
# starts, binds nothing, and fails to log in for a reason that looks unrelated.
cleanup(){
  [ -f "$T/sshd.pid" ] && kill "$(cat "$T/sshd.pid")" 2>/dev/null
  [ -n "${SSH_AGENT_PID:-}" ] && kill "$SSH_AGENT_PID" 2>/dev/null
  pkill -f "sshd -f $T/sshd_config" 2>/dev/null
  for _hn in 127.0.0.1 localhost; do ssh-keygen -R "[$_hn]:${PORT:-22222}" >/dev/null 2>&1; done
  [ "${SNAPFABRIC_TEST_KEEP:-0}" = "1" ] && { echo "  (kept $T)"; return 0; }
  rm -rf "$T"
}
trap cleanup EXIT INT TERM

echo "snapfabric provision integration test"
echo

# --- throwaway sshd ------------------------------------------------------------
PORT=${SNAPFABRIC_TEST_PORT:-22222}
ssh-keygen -q -t ed25519 -f "$T/hostkey"   -N '' </dev/null 2>/dev/null
ssh-keygen -q -t ed25519 -f "$T/bootstrap" -N '' -C bootstrap </dev/null 2>/dev/null
cat > "$T/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $T/hostkey
AuthorizedKeysFile $T/authorized_keys
PidFile $T/sshd.pid
StrictModes no
PasswordAuthentication no
UsePAM no
PubkeyAuthentication yes
EOF
cat "$T/bootstrap.pub" > "$T/authorized_keys"; chmod 600 "$T/authorized_keys"

# Every run generates a fresh host key for the same address, so a leftover
# known_hosts entry from a previous run is a HOST KEY MISMATCH. provision uses
# StrictHostKeyChecking=accept-new, which correctly refuses a *changed* key --
# the connection then fails for a reason that reads like "no login available".
# Both names: the backup path connects to 127.0.0.1, the hub loopback path to
# localhost, and each is a separate known_hosts entry.
for _hn in 127.0.0.1 localhost; do ssh-keygen -R "[$_hn]:$PORT" >/dev/null 2>&1; done

if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  skipm "port $PORT is already in use — set SNAPFABRIC_TEST_PORT to something free"
  printf "\n  %d passed, %d failed, %d skipped\n\n" "$pass" "$fail" "$skip"
  exit 0
fi

SSHD=/usr/sbin/sshd; [ -x "$SSHD" ] || SSHD=$(command -v sshd 2>/dev/null)
if [ -z "${SSHD:-}" ] || ! "$SSHD" -f "$T/sshd_config" -E "$T/sshd.log" 2>/dev/null; then
  skipm "cannot start a throwaway sshd — provision integration not exercised"
  printf "\n  %d passed, %d failed, %d skipped\n\n" "$pass" "$fail" "$skip"
  exit 0
fi
sleep 1

ME=$(id -un)
SSHB="ssh -p $PORT -i $T/bootstrap -o IdentitiesOnly=yes -o BatchMode=yes \
 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
if ! $SSHB "$ME@127.0.0.1" true 2>/dev/null; then
  skipm "throwaway sshd started but will not accept a login — skipping"
  printf "\n  %d passed, %d failed, %d skipped\n\n" "$pass" "$fail" "$skip"
  exit 0
fi
ok "throwaway sshd accepts a bootstrap login on 127.0.0.1:$PORT"

# provision bootstraps over whatever login already works, using ssh's DEFAULT
# identities -- it has no way to know about a key invented by a test.
#
# This used to borrow the developer's own ~/.ssh key and SKIP the entire suite
# when there wasn't one. That made the tests depend on who was running them, and
# it meant every CI runner -- which has no personal key -- reported "1 passed,
# 1 skipped", exit 0, having exercised nothing. A green suite that tested
# nothing is the exact failure this project exists to catch, and it was sitting
# in the suite itself.
#
# Instead: build a throwaway HOME with its own identity and run provision inside
# it. Hermetic, identical on a laptop and a CI runner, and it never reads or
# writes anything under the real ~/.ssh.
# provision bootstraps over whatever login already works, using ssh's default
# identities. It has no way to know about a key invented by a test.
#
# This used to borrow the developer's own ~/.ssh key and SKIP the whole suite
# when there wasn't one -- so the tests depended on who ran them, and every CI
# runner (which has no personal key) reported "1 passed, 1 skipped", exit 0,
# having exercised nothing. A green suite that tested nothing is the precise
# failure this project exists to catch, sitting inside the test suite.
#
# Overriding $HOME does not work: OpenSSH expands the ~ in its default
# IdentityFile from the passwd database, not from $HOME, so the test's key is
# never offered. An agent is the honest fix -- it is also how plenty of people
# genuinely bootstrap -- and it exercises provision exactly as shipped rather
# than adding a knob that only tests use.
if ! command -v ssh-agent >/dev/null 2>&1; then
  skipm "no ssh-agent available to hold the bootstrap identity"
  printf "\n  %d passed, %d failed, %d skipped\n\n" "$pass" "$fail" "$skip"
  exit 0
fi
eval "$(ssh-agent -s -a "$T/agent.sock" 2>/dev/null)" >/dev/null 2>&1
export SSH_AUTH_SOCK="$T/agent.sock"
if ! ssh-add "$T/bootstrap" >/dev/null 2>&1; then
  bad "could not load the bootstrap identity into the test agent"
  printf "\n  %d passed, %d failed, %d skipped\n\n" "$pass" "$fail" "$skip"
  exit 1
fi

# --- plan-shaped config --------------------------------------------------------
mkdir -p "$T/conf/hosts" "$T/src/sub" "$T/dest" "$T/rbin" "$T/hubbin" "$T/agents"
echo "payload" > "$T/src/sub/file.txt"
cat > "$T/conf/snapfabric.conf" <<EOF
BACKUP_ROOT="$T/dest"
MANAGED_VOLUMES="none"
HUB_USER="$ME"
HUB_HOST="127.0.0.1"
HUB_PORT=$PORT
HUB_KEY="$T/key_hub"
REMOTE_CMD="$T/hubbin/snapfabric-remote"
BACKUP_HOSTS="tgt"
PUSH_HOSTS=""
PULL_LABEL_PREFIX="local.snapfabrictest.pull"
EOF
cat > "$T/conf/hosts/tgt.conf" <<EOF
HOST_TAG="tgt"
SSH_USER="$ME"
SSH_HOST="127.0.0.1"
SSH_PORT=$PORT
SSH_KEY="$T/key_tgt"
DEST_ROOT="$T/dest"
SOURCES="$T/src"
EXCLUDES=""
SCHEDULE="daily"
REMOTE_BIN="$T/rbin"
REMOTE_AUTHKEYS="$T/authorized_keys"
EOF

run_prov(){
  # SSH_AUTH_SOCK, not HOME: see the agent comment above.
  SSH_AUTH_SOCK="$T/agent.sock" \
  GIT_SSH_COMMAND="" SNAPFABRIC_BIN_DIR="$T/hubbin" ALLOW_SYSTEM_DISK=1 \
  SNAPFABRIC_LAUNCHD_DIR="$T/agents" SNAPFABRIC_NO_ACTIVATE=1 \
  SNAPFABRIC_SYSTEMD_DIR="$T/units" \
  SNAPFABRIC_LOCALHOST_PORT="$PORT" HUB_LOCALHOST_KEY="$T/lo_key" \
  SNAPFABRIC_HUB_AUTHKEYS="$T/authorized_keys" \
  bash "$PROV" --conf "$T/conf" --plain --yes >"$T/prov.log" 2>&1
  echo $?
}

# --- 1. it provisions ------------------------------------------------------------
rc=$(run_prov)
if [ "$rc" = "0" ] && grep -q "1 provisioned" "$T/prov.log"; then
  ok "provision completes against a real sshd"
else
  bad "provision failed (rc=$rc): $(tail -3 "$T/prov.log" | tr '\n' ' ')"
fi

for want in "shell denied" "rsync read works" "rsync write denied"; do
  grep -q "$want" "$T/prov.log" && ok "verified: $want" || bad "did not verify: $want"
done

# --- 1b. the hub verb API ---------------------------------------------------------
# `status` and `doctor` speak to the hub through snapfabric-remote and nothing
# else. provision installed neither the script nor the key it answers, so both
# commands reported UNREACHABLE / CRITICAL on a healthy fabric for anyone who
# had not built their hub by hand. Nothing caught it because every test drove
# provision and the engine directly, never the two commands layered on top.
if [ -x "$T/hubbin/snapfabric-remote" ]; then
  ok "provision installs the verb API on the hub"
else
  bad "provision did not install snapfabric-remote — status and doctor cannot work"
fi
[ -f "$T/key_hub" ] && ok "provision generates the hub key" \
                    || bad "provision did not generate the hub key"
for want in "hub shell denied" "hub verb API answers"; do
  grep -q "$want" "$T/prov.log" && ok "verified: $want" || bad "did not verify: $want"
done

# The point of all of it: `snapfabric status` must actually report.
st_out=$(SNAPFABRIC_CONF="$T/conf/snapfabric.conf" bash "$ROOT/agents/common/snapfabric-status.sh" --plain 2>&1)
st_rc=$?
if printf '%s' "$st_out" | grep -qi "UNREACHABLE"; then
  bad "status still cannot reach the hub after a full provision"
  printf '%s\n' "$st_out" | head -3 | sed 's/^/        /'
else
  ok "status reaches the hub after provision (rc=$st_rc)"
fi

# --- 2. the restriction is real, not assumed --------------------------------------
# Strip the forced command and confirm provision NOTICES. A verification step
# that cannot fail is decoration.
cp "$T/authorized_keys" "$T/ak.good"
sed 's/^command="[^"]*",[^ ]* //' "$T/ak.good" > "$T/authorized_keys"
rc=$(run_prov)
if [ "$rc" != "0" ] && grep -q "grants a SHELL" "$T/prov.log" && grep -q "can WRITE" "$T/prov.log"; then
  ok "an unrestricted key is detected and the host is refused"
else
  bad "an unrestricted key was accepted as provisioned (rc=$rc)"
fi
cp "$T/ak.good" "$T/authorized_keys"
rm -f /tmp/.snapfabric-write-probe

# --- 3. idempotent ----------------------------------------------------------------
before=$(cksum < "$T/authorized_keys")
rc=$(run_prov)
after=$(cksum < "$T/authorized_keys")
n=$(grep -c 'snapfabric-tgt' "$T/authorized_keys")
if [ "$rc" = "0" ] && [ "$before" = "$after" ] && [ "$n" -eq 1 ]; then
  ok "re-running provision changes nothing and does not duplicate the key"
else
  bad "not idempotent: rc=$rc, snapfabric-tgt lines=$n"
fi

# --- 4. the generated launchd job is well-formed ----------------------------------
PLIST="$T/agents/local.snapfabrictest.pull.tgt.plist"
if [ -f "$PLIST" ]; then
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$PLIST" >/dev/null 2>&1 && ok "generated plist is valid" || bad "generated plist is malformed"
  else
    ok "generated a scheduler unit"
  fi
else
  [ "$(uname -s)" = "Darwin" ] && bad "no plist generated" || ok "non-macOS hub: no plist expected"
fi

# --- 5/6. end to end, through the shipped verifier ---------------------------------
# The point of provisioning is a working backup, not a configured one. This
# deliberately calls snapfabric-verify.sh rather than re-implementing SHA-256 and
# inode checks here: a verifier in the test and a different verifier in the tool
# is the same writer/reader divergence that constraint 21 exists to prevent.
cp "$ENGINE" "$T/hubbin/"
ALLOW_SYSTEM_DISK=1 LOG_DIR="$T/elog" bash "$T/hubbin/snapshot-engine.sh" "$T/conf/hosts/tgt.conf" >/dev/null 2>&1
sleep 1
ALLOW_SYSTEM_DISK=1 LOG_DIR="$T/elog" bash "$T/hubbin/snapshot-engine.sh" "$T/conf/hosts/tgt.conf" >/dev/null 2>&1

VERIFY="$ROOT/agents/common/snapfabric-verify.sh"
if bash "$VERIFY" --conf "$T/conf" --plain >"$T/verify.log" 2>&1; then
  grep -q "restore verified" "$T/verify.log" && ok "verify: restore proven by SHA-256 against the source" \
                                             || bad "verify exited 0 without verifying anything"
else
  bad "verify failed on a good backup: $(tail -3 "$T/verify.log" | tr '\n' ' ')"
fi
grep -q "hardlinked to" "$T/verify.log" && ok "verify: confirms snapshots are hardlinked, not full copies" \
                                        || bad "verify did not check hardlinking"

# A verifier that cannot fail is decoration. Corrupt a file INSIDE the backup and
# confirm verify reports a mismatch rather than a pass.
CORRUPT=$(find "$T/dest" -name file.txt | head -1)
cp "$CORRUPT" "$T/file.orig"; chmod u+w "$CORRUPT"; printf 'CORRUPTED' > "$CORRUPT"
if bash "$VERIFY" --conf "$T/conf" --plain >"$T/verify2.log" 2>&1; then
  bad "verify passed a backup whose content had been corrupted"
else
  grep -q "MISMATCH" "$T/verify2.log" && ok "verify: detects a corrupted file in the backup" \
                                      || bad "verify failed but not for the corruption"
fi
cp "$T/file.orig" "$CORRUPT"

# --- 7. a set-but-unreachable sentinel fails the host -----------------------------
# constraint 26: a soft warning on a hard-fail condition is a lie.
# The engine refuses to run without a configured sentinel, so a host whose
# sentinel is wrong can never back up. Reporting it as provisioned would be the
# exact "looks provisioned, isn't" failure the script exists to prevent.
cp "$T/conf/hosts/tgt.conf" "$T/tgt.conf.bak"
echo 'SENTINEL="/no/such/path/at/all"' >> "$T/conf/hosts/tgt.conf"
rc=$(run_prov)
if [ "$rc" != "0" ] && grep -q "sentinel /no/such/path/at/all is not visible" "$T/prov.log"; then
  ok "a configured sentinel that is missing fails the host"
else
  bad "a missing sentinel was accepted (rc=$rc)"
fi

# and a correct one passes
cp "$T/tgt.conf.bak" "$T/conf/hosts/tgt.conf"
echo "SENTINEL=\"$T/src/sub/file.txt\"" >> "$T/conf/hosts/tgt.conf"
rc=$(run_prov)
if [ "$rc" = "0" ] && grep -q "sentinel visible" "$T/prov.log"; then
  ok "a reachable sentinel is verified and the host provisions"
else
  bad "a valid sentinel was rejected (rc=$rc)"
fi

printf "\n  %d passed, %d failed, %d skipped\n\n" "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || exit 1
