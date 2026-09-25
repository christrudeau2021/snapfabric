# Security Model

snapfabric takes SSH credentials, writes scripts to remote hosts, and needs
elevated privileges to schedule jobs and mount volumes. That is a meaningful
amount of trust. This document states plainly what it does, what it is exposed
to, and where the sharp edges are.

Claims here about what the tooling actually does are enforced by the test
suites, and cited so you can check them rather than take my word for it. See
[`tests/test-provision.sh`](../tests/test-provision.sh), which provisions
against a throwaway `sshd` and then tries to break out of each restriction.

---

## What the tool holds

| Secret | Where | Protection |
|---|---|---|
| Per-host backup private keys | Hub, `~/.ssh/snapfabric_<host>` | mode `600`, never leaves the hub |
| Hub self-key (macOS only) | Hub, `~/.ssh/snapfabric_localhost` | mode `600`; needed to inherit sshd's Full Disk Access |
| Login passwords | **Never stored** | Prompted once during `provision`, used to install a key, discarded |

**Passwords are never written to disk, logs, or config.** If a password is
needed again, the operator is prompted again.

---

## Principle of least privilege — and where it is not achieved

### Backup keys: properly restricted

Each host gets a dedicated key locked to a forced command that permits only
read-only rsync:

```
command="~/bin/snapfabric-rsync-only",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc ssh-ed25519 …
```

The wrapper accepts only `rsync --server --sender …`. Anything else — a shell,
a write-mode rsync, scp — is refused.

**This is verified, not asserted.** `provision` refuses to schedule a host until
it has observed three things through that key: a shell is denied, an rsync read
succeeds, and an rsync write is denied. Shell-denial alone is not sufficient
evidence — a key that denies everything would pass it while backing nothing up.
The same three checks run in CI against a throwaway `sshd`
(`tests/test-provision.sh`), and the suite deliberately strips the forced
command to confirm provision NOTICES.

The checks use `IdentitiesOnly=yes`. Without it ssh also offers agent keys and
the operator's default identities, and the question "what does THIS key permit?"
gets answered by whichever key happens to work.

### Watchdog key: the largest exposure, and how it is contained

The watchdog runs on a second machine so it can report the hub being down. To
repair the hub it needs `launchctl`, `diskutil`, and therefore `sudo`.

**Before this was fixed, the watchdog key granted a full shell** on the hub plus
passwordless root:

```
shell: ALLOWED as <hubuser>
sudo:  ALLOWED as root
```

**Consequence:** compromising the watchdog host yields **root on the backup
hub** — the machine holding every backup. The watchdog runs on whichever box is
always on, which in most home labs is also the one running the most services and
therefore carrying the most attack surface. That is a poor place to keep a key
this powerful.

**Contained.** The watchdog key is a forced command
pointing at `snapfabric-remote`, a small verb dispatcher. The watchdog can only
invoke:

| Verb | Argument validation |
|---|---|
| `ping` | none |
| `status` | none — read-only, returns the whole picture in one round trip |
| `mount <volume>` | volume must be in the allowlist |
| `fix-mountpoint <volume>` | volume must be in the allowlist |
| `restart-service <label>` | label must be in the allowlist |
| `run-backup <host>` | host must be in the allowlist |

A **verb API rather than a command filter** is deliberate: filtering arbitrary
shell with patterns is fragile — too loose buys nothing, too tight breaks the
watchdog silently. Here there is no path to an arbitrary command at all, and
every argument is rejected if it contains shell metacharacters or whitespace.

**Verified by attempting to escalate.** All refused:

```
id                              BLOCKED
sudo id                         BLOCKED
cat /etc/passwd                 BLOCKED
rm -rf /tmp/x                   BLOCKED
restart-service com.apple.smbd  BLOCKED   (label not in allowlist)
mount Macintosh HD              BLOCKED   (volume not in allowlist)
run-backup ../../etc            BLOCKED   (host not in allowlist)
status; id                      BLOCKED   (metacharacter)
ping && id                      BLOCKED   (metacharacter)
```

Self-healing still works end-to-end: the advertiser was deliberately booted out
and the watchdog detected, repaired, and verified it through the verb API alone.

**Residual risk:** `run-backup` and `restart-service` can still be invoked at
will by whoever holds the key, so a compromised watchdog host could cause
resource churn on the hub. It can no longer read, write, or destroy backup data,
nor obtain a shell.

### Hub sudo

Scheduling, mounting and Time Machine operations need root without an
interactive prompt, so a hub is commonly set up with passwordless sudo for the
operator's account. If you do that, **anyone who obtains that login gets root
with no further challenge** — including through any backup key that turns out to
be less restricted than it should be. It is reversible (`sudo rm
/etc/sudoers.d/<file>`), and worth avoiding where the schedule does not need it:
a user LaunchAgent, which is what `provision` installs, does not.

---

## The backup drive is not encrypted

snapfabric does not encrypt anything, and does not check whether you have.
Confirm with `diskutil info <volume>` (macOS) or `lsblk -o NAME,FSTYPE` (Linux).

Backups contain SSH private keys, browser profiles, keychains, and application
secrets **in the clear**. Anyone with physical access to the drive can read all
of it, with no login required.

This is true of every backup system. It is called out because:

- APFS encryption **cannot be added after the fact** — it requires recreating
  the volume, which means re-seeding every backup
- So it is a decision to make at setup time, or not at all

**`snapfabric plan` does not currently ask about this, and it should.** Written
here as a known gap rather than a design decision: because the choice cannot be
revisited without re-seeding, silently defaulting to unencrypted is the one
default that is expensive to change your mind about.

---

## Attack surface

| Vector | Exposure | Mitigation |
|---|---|---|
| Compromised watchdog host | **Root on the hub** | Restrict the watchdog key (above) |
| Compromised hub | All backups readable and destroyable; sudo without password | Physical security; the hub is the crown jewel |
| Compromised backed-up host | Read-only rsync only — cannot write to the hub or reach other hosts | Forced command per key |
| Stolen backup drive | Full plaintext access to everything | Volume encryption at creation |
| Malicious config file | `snapshot-engine.sh` **sources** the config as shell — arbitrary execution | Config must be owned by the running user, mode `600`; never accept one from an untrusted source |

That last row is deliberate: the config is plain shell so operators can read and
extend it. The trade-off is that a writable config is equivalent to code
execution. `provision` writes it `600` and owned by the running user.

---

## What was checked before this was published

- **No private keys, passwords or tokens are committed.** Every `ssh-ed25519`
  occurrence in this repository is an elided placeholder in documentation. The
  test suites generate keys at runtime in a temp directory.
- **Nothing describes a real network.** Every host, address, volume, path and
  service name comes from the operator's config. This was verified by scanning
  the working tree *and* every commit — an earlier scan covered only the working
  tree, which was a false assurance: the history at that point still contained a
  full LAN inventory, and the repository was rebuilt from a single clean commit
  because of it.
- **The backup key restriction is enforced, not assumed** — see above, and
  `tests/test-provision.sh`.
- **The watchdog key is a forced command by default**, not an opt-in.

## Reporting a problem

See [`SECURITY.md`](../SECURITY.md) in the repository root for how to report a
security issue privately, and for the list of known design limits that are not
considered vulnerabilities.
