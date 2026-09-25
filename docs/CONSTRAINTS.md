# Constraints and Hard-Won Rules

Every item below cost a real failure in a running lab. They are recorded here
so the implementation can encode them as **tested behaviour** rather than
rediscovering each one.

Format: **what looks reasonable** → **what actually happens** → **what to do**.

---

> Each rule carries a **Tested:** marker. `yes` means a test in `tests/` fails if
> the behaviour regresses; `no` means the rule is documented and understood but
> nothing yet enforces it. Currently **20 of 36** are covered. The unmarked half
> is a backlog, not a claim — several describe macOS platform behaviour (System
> Settings gates, TCC) that a test cannot assert without a GUI, and the rest are
> simply not written yet.
>
> A rule whose marker says `yes` is cited by number from the suite, so the
> mapping can be checked rather than trusted.


## 1. macOS gates sharing services behind System Settings

**Tested:** no — documented, not yet covered by a test

**Looks reasonable:** enable File Sharing with `sharing -a` and `launchctl`.

**Actually happens:** the daemon starts and port 445 listens, but share points
are never exported. The client sees *"the share does not exist"* — note this
error appears only **after** authentication succeeds, which is how you tell it
apart from a credential problem. macOS also auto-exports user home directories
even with File Sharing off, so a successful `bind_tree` in the smbd log proves
nothing about your share.

**Ruled out, all of them:**
`sharing -a` · `dscl … smb_timemachine` · `TimeMachineSharePoints` plist key ·
`.metadata_never_index` marker · `launchctl enable/bootstrap/bootout/kickstart` ·
`killall -HUP smbd` · `ARDAgent kickstart` for Screen Sharing

Apple's own tool states it outright:
> *"Screen Sharing or Remote Management must be enabled from System Settings or via MDM."*

**Do:** detect the gap, print the exact click path, and **verify** after the
operator says they've done it. Never claim success without re-checking.

---

## 2. Homebrew Samba is not a workaround for #1

**Tested:** no — documented, not yet covered by a test

**Looks reasonable:** sidestep Apple's smbd with Samba + the `fruit` VFS module —
the standard TrueNAS/Synology approach.

**Actually happens:** Samba 4.24.5 serves and authenticates correctly, the share
enumerates, files write — but **every directory it creates comes out mode `000`**,
so Time Machine fails with *"the backup disk image could not be created."*

**Ruled out:** `create mask=0666` / `directory mask=0777` · `force create mode` /
`force directory mode` · `inherit permissions = yes` · explicit `umask 022` at
launch · `vfs objects =` (empty) · `nt acl support = no` · internal **and**
external target volumes. Samba's own `smbclient` fails identically, so it is
server-side, not a client quirk.

**Do:** don't. Uninstall and re-enable Apple's smbd.

---

## 3. TCC denies launchd jobs access that an interactive shell has

**Tested:** no — documented, not yet covered by a test

**Looks reasonable:** a launchd job runs as you, so it can read your files.

**Actually happens:** scheduled jobs are **denied** `~/Documents`, `~/Desktop`,
`~/Downloads` while Terminal reads them fine. Worse, launchd jobs are denied
**write access to external volumes even running as root**.

**Do — two separate remedies:**

- *Reading protected user folders:* the job's interpreter needs Full Disk
  Access (System Settings → Privacy & Security → Full Disk Access → add
  `/bin/bash`). Cannot be automated. Until granted, the agent must **refuse to
  run** rather than produce a partial backup.
- *Writing to an external volume:* have the scheduled job invoke itself through
  `ssh localhost`. Processes spawned by `sshd` inherit its Full Disk Access.
  This is why the production launchd plists call
  `ssh -i ~/.ssh/snapfabric_localhost <user>@localhost <script>` instead of the script
  directly. **Do not "simplify" that away.**

---

## 4. Time Machine deletes APFS quotas; only reservations survive

**Tested:** no — documented, not yet covered by a test

**Looks reasonable:** cap a Time Machine volume with `diskutil apfs addVolume … -quota`.

**Actually happens:** the quota survives `setdestination` and `enable`, then
**Time Machine removes it the moment a backup starts** — observed jumping
2.3 TiB → 7.3 TiB. APFS volumes share container free space, so an unquotaed
Time Machine volume will grow until it starves everything else.

**Do:** protect the *other* volumes with `-reserve`, which Time Machine cannot
strip. Both `-reserve` and `-quota` can **only be set at volume creation** —
there is no verb to add either later. Plan the layout before creating volumes.

---

## 5. openrsync has no `--sparse`

**Tested:** yes — `tests/`

**Looks reasonable:** `rsync -a` copies a sparse file efficiently.

**Actually happens:** macOS 15+ ships **openrsync**, which has no `--sparse`
option. Docker Desktop's `Docker.raw` — 9.7 GB on disk, ~1 TB logically —
inflated to **926 GB** and filled the backup volume.

**Do:** exclude known sparse offenders explicitly (`Docker.raw`,
`com.docker.docker`, VM images). Add a post-run **inflation guard**: if the
snapshot exceeds ~130% of the source, log loudly and name the likely culprit.
openrsync *does* support `--link-dest`, `--numeric-ids`, `--partial`, `--stats`
— but **not** `--human-readable`.

---

## 6. Never rename a failed run out of the resume path

**Tested:** yes — `tests/`

**Looks reasonable:** rename a failed snapshot to `FAILED_<stamp>` so it's
obviously bad and `latest` keeps pointing at the last good one.

**Actually happens:** catastrophic. The partial is the most complete copy of the
source in existence. Renaming it hides it from the hardlink base, so the next
run starts a **full copy from zero**. Three consecutive ~900 GB partials filled
the volume; being full then guaranteed the next run also failed. In a separate
incident, 13 `FAILED_` directories accumulated until the drive hit 100% and every
backup died with `ENOSPC`.

**Do:** keep the dated name. Have the next run fall back to the newest existing
snapshot as `--link-dest` even if incomplete — rsync verifies size and mtime
per file, so reusing a partial is safe and turns a **restart into a resume**.

---

## 7. Retention must run on failure, not only on success

**Tested:** yes — `tests/`

**Looks reasonable:** prune old snapshots after a successful run.

**Actually happens:** a host that *never* succeeds accumulates partials forever
with nothing to clean them. media built up 9 snapshots and filled the volume;
`latest` never advanced because it only advances on success, so every run
re-copied everything new against a stale base. Self-reinforcing.

**Do:** prune on the failure path too — keep the oldest (the shared hardlink
base) plus the two newest, drop the middle. Add a deadlock guard: if the volume
is ≥95% full when a run fails, discard that run's own partial immediately.

---

## 8. Deleting hardlinked copies frees nothing

**Tested:** no — documented, not yet covered by a test

**Looks reasonable:** the volume is full, so delete the `FAILED_` directories.

**Actually happens:** they were hardlinked to live snapshots. Removing one link
releases almost no space. Deleting 13 of them freed essentially nothing.

**Do:** measure with `du` before assuming a deletion will help, and check link
counts (`stat -f %l`) to know whether data is shared.

---

## 9. Measure before deleting — directory count is not size

**Tested:** no — documented, not yet covered by a test

**Looks reasonable:** when choosing which partial to keep, keep the one whose
directory structure most closely matches the source.

**Actually happens:** those directories can be empty shells. The snapshot with
the *most complete top-level structure* held **36 GB**; the one discarded held
**853 GB**.

**Do:** `du -sh` every candidate and keep the largest. Never judge completeness
by structure.

---

## 10. Snapshot counts prove nothing — hash-verify restores

**Tested:** no — documented, not yet covered by a test

**Looks reasonable:** the job logged "snapshot complete", so the backup is good.

**Actually happens:** completion proves a process exited zero. It says nothing
about whether the bytes are correct or restorable.

**Do:** restore a real file and compare `shasum -a 256` against the live source.
Do it per host, on a schedule. *A backup unverified by restore is not a backup.*

---

## 11. Detection is not repair — verify every repair

**Tested:** no — documented, not yet covered by a test

**Looks reasonable:** the watchdog found the service down and restarted it.

**Actually happens:** `launchctl kickstart` silently no-ops if the job was
booted out entirely; it only works on an already-loaded job. The repair reported
success while doing nothing.

**Do:** fall back to `bootstrap` from the plist, then **re-check that the process
actually came back**. Every repair path needs a verification step, and every
repair path needs testing against a deliberately broken target.

---

## 12. Check the mount *path*, not just "is it mounted"

**Tested:** no — documented, not yet covered by a test

**Looks reasonable:** `diskutil info /Volumes/Backups` succeeds, so we're fine.

**Actually happens:** after a USB re-enumeration (`disk6` → `disk7`) with a stale
directory squatting the mount point, macOS mounts the volume as
**`/Volumes/Backups 1`**. The volume is perfectly healthy; every script pointing
at the original path fails. A watchdog asking only "is it mounted?" misses this
entirely — it went unnoticed for a full day.

**Do:** compare the **volume name reported by `diskutil info <expected path>`**
against the expected name. To repair: unmount the wrong path, **move** the
squatting directory aside (`mv <mp> <mp>.stale-<timestamp>`), remount by volume
name, re-verify. `rmdir` fails on a non-empty stale directory — and **never
`rm -rf` a `/Volumes` path in automation**; one misidentification deletes a
mounted backup volume.

---

## 13. Container free space hides per-volume exhaustion

**Tested:** no — documented, not yet covered by a test

**Looks reasonable:** the APFS container reports 33% free, so there's room.

**Actually happens:** an individual volume can sit at **98% of its own quota**
while the container looks healthy. Writes to that volume start failing with no
warning from a container-level check.

**Do:** monitor **both** — per-volume fill (warn 85%, critical 95%) and container
free (warn <15%, critical <8%).

---

## 14. A monitor that cries wolf is worse than no monitor

**Tested:** no — documented, not yet covered by a test

**Looks reasonable:** parse `diskutil` output by field position.

**Actually happens:** `Capacity Not Allocated: 4341524299776 B (4.4 TB) (54.6% free)` —
field 6 is `4.4`, the *terabytes*, not the percentage. The watchdog reported a
false **CRITICAL "4.4% free"** on a 54.6%-free container. Leading whitespace
shifts fields further.

**Do:** match the token (`grep -oE "[0-9.]+% free"`), never count fields. Validate
every parser against real output before trusting an alert.

---

## 15. Small operational traps

**Tested:** yes — `tests/`

| Trap | Consequence | Fix |
|---|---|---|
| macOS ships **bash 3.2** | `declare -A` silently misbehaves; empty-array expansion under `set -u` throws "unbound variable" | Use `case` functions; always populate arrays before expanding |
| Hardcoded disk identifier | `disk6` → `disk7` after re-enumeration; the check silently breaks | Resolve the container dynamically from the mount point |
| Logging to `/var/log` | A cron job died silently for weeks because the user couldn't write there | Log to a path the running user owns |
| Running a watchdog as root via `sudo` | `$HOME` becomes `/root`; key paths break | Run as the owning user |
| Missing `StrictHostKeyChecking=accept-new` | "host unreachable" when the host is healthy — a fresh account has no `known_hosts` | Set it explicitly in automation |
| `$(date)` inside single quotes in a remote command | No substitution; every file gets the literal name and collides | Compute locally, interpolate |
| Overwriting a running script in place | bash reads scripts incrementally; the live process executes garbage | Write to a temp name and `mv` — rename swaps the directory entry, the running process keeps its inode |
| No single-instance lock | A long seed overlaps its own next scheduled run | Atomic `mkdir` lock with stale reclaim (macOS has no `flock`) |
| Spotlight indexing backup volumes | ~800 GB of index, constant I/O contention | `mdutil -i off` per volume. Time Machine volumes refuse it — macOS reclaims them |
| `find` not following `latest` | Reports 0 files and looks like data loss | Use `find -L` or the resolved path |
| `tmutil` exits 0 while printing failure | "Success" on a failed operation | Verify by re-reading `destinationinfo`, never trust the exit code |

---

## 16. Backups contain secrets

**Tested:** no — documented, not yet covered by a test

The backup drive holds SSH private keys, browser profiles, keychains, and
application secrets **in the clear** unless the volume is encrypted. This is
true of every backup system; it is worth stating plainly to any operator before
they point this at their home directory.

**Do:** say so in the quickstart. Offer encryption as an explicit choice at
volume-creation time — it cannot be added later without recreating the volume.

---

## 17. On macOS, `/` is not the system disk you think it is

**Tested:** yes — `tests/`

**Looks reasonable:** guard against writing to the hub's internal disk by
comparing the destination's device against the device backing `/`.

**Actually happens:** on macOS `/` is the **sealed, read-only system volume**
(e.g. `disk3s1s1`) while all user data lives on `/System/Volumes/Data`
(`disk3s5`). A path like `/tmp` therefore reports a *different* device from `/`,
the comparison passes, and the guard silently does nothing — on the platform
that needs it most. Caught only by deliberately pointing the engine at `/tmp`
and noticing it did not refuse.

**Do:** compare the destination device against **every** system filesystem —
`/`, `/System/Volumes/Data`, `/home`, `/var` — not just `/`. And test the guard
by aiming it somewhere it must refuse; a guard never observed failing is a guard
never tested.

---

## 18. Word-splitting silently corrupts paths with spaces

**Tested:** yes — `tests/`

**Looks reasonable:** iterate sources with `for src in $SOURCES`.

**Actually happens:** unquoted expansion splits on spaces, so
`/srv/My Documents` becomes two bogus sources — `/srv/My` and
`Documents` — and rsync happily "backs up" neither. `/Volumes/My Drive` is an
entirely ordinary macOS path, so this is not an edge case. Exclude patterns have
the same problem (`/Application Support/`). Caught only by deliberately testing
a path containing a space.

**Do:** make SOURCES and EXCLUDES newline-delimited, set `IFS` to newline while
iterating, and build the rsync argv with `set -- "$@" "--exclude=$pat"` rather
than flattening into one string. Verify by running with `RSYNC=/bin/echo` and
reading the actual argv.

---

## 19. A push host has no scheduler on the hub

**Tested:** yes — `tests/`

**Looks reasonable:** derive one scheduler label per backed-up host.

**Actually happens:** hosts that *push* to the hub (laptops, which are not
reliably reachable) run their own agent and have no hub-side job. Generating a
label for them makes the health check report a permanently "missing" service,
and the watchdog then tries — forever — to repair something that should not
exist. A monitor that reports a fault which cannot be fixed trains the operator
to ignore it.

**Do:** keep an explicit `PUSH_HOSTS` list. Exclude those hosts from scheduler
labels, refuse `run-backup` for them with a clear reason, and have the watchdog
report them stale without attempting a trigger.

---

## 20. `set -o pipefail` breaks capability detection

**Tested:** no — documented, not yet covered by a test

**Looks reasonable:** detect a tool's features by grepping its help output.

```bash
if nc -h 2>&1 | grep -q -- '-G'; then …
```

**Actually happens:** many tools exit non-zero when printing help — `nc -h`
returns 1. Under `set -o pipefail` the pipeline reports failure **even though
grep matched**, so the branch is silently skipped. Here it selected a fallback
whose timeout flag does not bound the TCP *connect* on macOS, leaving network
probes effectively unbounded: a /24 scan took 84 seconds instead of 10.

The failure is invisible — the wrong branch works, just badly. It only surfaced
by instrumenting each phase with timestamps after the runtime looked wrong.

**Do:** capture the output first, then test it.

```bash
_help=$(nc -h 2>&1 || true)
printf '%s' "$_help" | grep -q -- '-G' && …
```

**Related:** a `/24` ping sweep leaves an ARP entry for **every** address it
tried — 230 of 255 were `(incomplete)` here. Filter those out before probing, or
you spend a timeout on each dead address.

---

## 21. Testing the reader is not testing the writer

**Tested:** yes — `tests/`

**Looks reasonable:** there is a test proving a source path containing a space
survives — constraint 18 is covered.

**Actually happens:** that test hands the *engine* a hand-written config. It
says nothing about the tool that *generates* configs. When `plan` was added, a
one-line change to make it join `SOURCES` with spaces instead of newlines
reintroduced constraint 18 in full — and the entire suite stayed green, because
every existing test exercised the consuming half of a path whose producing half
had never been tested at all.

**Do:** for anything that writes a config another component reads, test the
round trip — generate with the writer, consume with the reader, assert on the
reader's behaviour. Drive the interactive flow from a here-doc so it is
scriptable.

**And anchor the assertion.** The first version of that round-trip test *still*
passed under the space-joining mutation:

```bash
grep -q "syncing /srv/My Documents" "$log"      # matches "syncing /srv/My Documents /opt"
grep -q "syncing /srv/My Documents$" "$log"     # and also count the sources
```

An unanchored match on a concatenation of the values you are checking is not a
check. Verify a new test fails by deliberately breaking the thing it guards —
twice now a green test here was green for the wrong reason.

---

## 22. `eval "$name=…"` collides with the callee's own locals

**Tested:** yes — `tests/`

**Looks reasonable:** a prompt helper that fills a variable the caller names.

```bash
ask(){ local __v="$1" __a; read -r __a; eval "$__v=\$__a"; }
ask_yn(){ local __a; ask __a "$1"; case "$__a" in [Yy]*) return 0;; esac; }
```

**Actually happens:** `ask_yn` passes the name `__a`, which is also `ask`'s own
local. `eval "__a=\$__a"` assigns to the *callee's* local and the value never
reaches the caller. Every y/n prompt silently took the else branch — including
"Write this plan?", so a completed interactive session exited saying *aborted —
nothing written*. Nothing errors; the wrong answer is simply always used.

**Do:** give indirect-assignment helpers distinctively prefixed locals
(`__sf_a`), and say in a comment that callers must not reuse those names. bash
3.2 has no `local -n`, so there is no language-level fix.

---

## 23. Config values that must agree cannot be asked for independently

**Tested:** yes — `tests/`

**Looks reasonable:** ask the operator for a schedule, then ask how stale a
backup may get before it is an alarm.

**Actually happens:** they pick `weekly` and leave the freshness limit at the
30-hour default, and the watchdog reports CRITICAL on a perfectly healthy host
forever — until it is ignored, which is worse than having no watchdog. Same
class as reading the wrong `df` field and alarming at "4.4% free" on a
half-empty container: the monitor is confidently wrong, and confident wrong
alarms train the operator to stop reading them.

**Do:** derive the dependent value and show the operator what you derived.

```
✓ weekly → the watchdog will call media stale after 210h
```

Interval plus 25% slack, floor six hours: one late run is not an alarm, two are.

---

## 24. Hardcoding port 22 fails at the wrong layer

**Tested:** yes — `tests/`

**Looks reasonable:** every host is on 22, so the SSH command is a fixed string.

**Actually happens:** the first host that is not on 22 produces

```
ERROR: rsync of /srv/data exited 255
```

255 is ssh's "I could not connect", passed through rsync unchanged. The engine
reports it as a *transfer* failure, so you go looking at rsync flags, the source
path, and disk space — none of which are the problem. It was found only by
testing against a throwaway sshd on a high port, which is exactly the case a
network of real hosts on 22 will never exercise.

**Do:** carry `SSH_PORT` per host from config through every component that
builds an ssh command — the engine, provision's reachability probes, and the
generated scheduler unit. Per host, not global: an estate can mix ports, and a
global default means provision verifies a host the backup will never reach.

---

## 25. A regenerated host key reads as "no login available"

**Tested:** no — documented, not yet covered by a test

**Looks reasonable:** `StrictHostKeyChecking=accept-new` is the right setting
for provisioning — it accepts a first-seen host and refuses a *changed* one.

**Actually happens:** a test harness that stands up a fresh sshd generates a new
host key for the same `host:port` every run. The second run is a host key
MISMATCH, ssh refuses, and the caller reports its own generic message —
*"no non-interactive login to <user>@127.0.0.1"* — which sends you to look at
keys and authorized_keys, not at `known_hosts`. The first run always passes and
every run after it fails, which reads like flakiness rather than state.

Two names, two entries: connecting to `127.0.0.1` and to `localhost` on the same
port are separate `known_hosts` lines, so clearing one still leaves the other.

**Do:** a harness that regenerates host keys must clear its own `known_hosts`
entries — for every name it connects by — on setup *and* teardown. Keep
`accept-new` in the tool: the setting is correct, the test was dirty.

**Related:** the same harness left an orphaned `sshd` holding the port when it
exited between fork and pidfile write. Kill by config path as well as by pid,
and check the port is free before binding — otherwise the next run talks to the
previous run's server, whose `authorized_keys` no longer exists.

---

## 26. A soft warning on a hard-fail condition is a lie

**Tested:** yes — `tests/`

**Looks reasonable:** provision cannot see a host's sentinel, so it warns and
carries on. The operator has been told; the run continues.

**Actually happens:** the engine *refuses to run* without a configured sentinel.
So the host is counted in "3 provisioned", appears configured, has a scheduler
job installed — and every scheduled run aborts at preflight. The warning scrolls
past during setup and is never seen again. The summary says green.

The first version of this was worse than wrong, it was incoherent: it probed the
first SOURCE rather than SENTINEL, and printed *"the engine will refuse to run"*
in the one case where the engine does nothing of the kind — an unset sentinel
disables the check entirely.

**Do:** match the severity to what actually happens downstream.

| Condition | Downstream reality | Correct response |
|---|---|---|
| SENTINEL set, not reachable | every run aborts | **fail the host**, do not schedule it |
| SENTINEL unset | runs fine, unmounted source undetected | warn, explain the exposure, continue |

If a step warns, the thing it warns about must be survivable. If it is not
survivable, refuse — the whole point of "refuse rather than partially succeed"
is that the summary line has to be true.

---

## 27. openrsync is not GNU rsync — feature-detect every flag

**Tested:** no — documented, not yet covered by a test

**Looks reasonable:** rsync is rsync. `-s` (`--protect-args`) has existed for
years, and constraint 18 says paths with spaces are real, so use it.

**Actually happens:** macOS `/usr/bin/rsync` is **openrsync**, a clean-room
reimplementation. It reports `protocol version 29` and rejects `-s` outright:

```
rsync: invalid option -- s
```

`verify` treated that as "the source no longer has this file" and reported every
single sample as drift — then exited 0 having verified nothing. A verifier that
silently verifies nothing is worse than no verifier, because it produces a green
line.

This is the same trap as the missing `--sparse` in constraint 8, on a different
flag. It will keep happening; the lesson is the class, not the flag.

**Do:** prefer a real rsync 3.x if one is installed, then feature-detect what
you use rather than assuming it.

```bash
for c in /opt/homebrew/bin/rsync /usr/local/bin/rsync /usr/bin/rsync; do
  [ -x "$c" ] && { RSYNC="$c"; break; }
done
_help=$("$RSYNC" --help 2>&1 || true)          # non-zero on --help; see rule 20
PROTECT=""; printf '%s' "$_help" | grep -q -- '--protect-args' && PROTECT="-s"
```

**And surface the error.** The first version discarded rsync's stderr to
`/dev/null`, so the message that named the problem exactly — `invalid option` —
was thrown away, and the failure presented as a missing source file. When a
command fails, report what it said.

---

## 28. Measure freshness from the last SUCCESS, not the last attempt

**Tested:** yes — `tests/`

**Looks reasonable:** the newest dated directory under a host is its latest
snapshot, so report its age.

**Actually happens:** a run in progress creates a dated directory the moment it
starts, and a run that fails leaves one behind. Both are newer than the last
good snapshot. So the dashboard showed

```
● media   2 snapshots · latest 4h ago        ← the truth was 10 DAYS
```

The 4-hour directory was a pull that started that afternoon and was still
running. Behind it were three consecutive failures — `No space left on device`
on the backup volume — and before those, the last completed snapshot, ten days
earlier. The verdict line said **ALL GREEN** the entire time.

`latest` is the right source of truth because it only advances when a run
completes. The engine already maintained it correctly; the reporting simply
read the wrong thing.

This was not found by reading the code or by any test. It was found by running
`verify` against real backups, which measures `latest` and immediately printed
*"snapshot <ten days earlier>, 243h old"* next to a dashboard claiming four
hours.

**Do:**

```bash
good=$(readlink "$ROOT/$host/latest" 2>/dev/null | sed 's|.*/||')   # completed
newest=$(ls -1 "$ROOT/$host" | grep '^[0-9]' | sort | tail -1)      # attempted
```

Report the age of `good`. When `newest` differs, say so beside it rather than
letting it stand in — *"last good 10d ago (+1 in progress/incomplete)"*. And if
there is no `latest` at all, say **never completed**; do not silently fall back
to the newest directory and call it fresh.

**The general rule:** a monitor must count successes. Counting attempts turns
the monitor into the thing that hides the outage.

---

## 29. Ask the machine what it has; do not ask the operator to recall it

**Tested:** yes — `tests/`

**Looks reasonable:** prompt for the backup drive and the source paths. The
operator knows their own lab.

**Actually happens:** they mistype it, or name a path that is not a mount point,
or point at a directory that only exists while something is mounted. Every one
of those becomes a backup that looks configured and silently protects nothing.
The machine already knows the answer — `df` has it.

So `plan` scans real filesystems and offers them as a numbered list, locally for
the backup root and (optionally, read-only, over `df`) on each host for its
sources. Typing a path always still works; the list is a shortcut, not a cage.

**Three things this got wrong on the first attempt, all worth keeping:**

**It has to be usable, not merely correct.** The first run on a Mac with Time
Machine active returned 26 filesystems — 23 of them local-snapshot mounts under
`/Volumes/com.apple.TimeMachine.localsnapshots/…`. Accurate, and completely
useless; a 26-item menu is no better than an empty prompt. Filter backup
machinery, hidden path components, container overlays and pseudo-filesystems,
and sort external drives first because that is what a backup tool is reaching
for.

**The order must be deterministic.** `sort` is not stable, so two external
drives came back in an arbitrary order and the menu numbering changed between
runs. Someone who picks "1" must get the same filesystem every time — sort on a
secondary key under `LC_ALL=C`.

**Mount points are exactly where the sentinel matters.** If a source is itself a
mount point, an unmounted source presents as an empty directory and `--delete`
propagates the emptiness. Because `plan` now knows which sources are mount
points, it offers a sentinel for them instead of leaving the field to be
discovered later.

---

## 30. A space-separated list cannot hold a macOS volume name

**Tested:** yes — `tests/`

**Looks reasonable:** `MANAGED_VOLUMES="Backups"` — a space-separated list of
volume names, iterated with `for v in $MANAGED_VOLUMES`.

**Actually happens:** the mount scan offered `/Volumes/My Backup Drive`,
which is **Apple's own default name** for a Time Machine drive. `plan` derived
the volume name from it, `safe_token` rejected the spaces, and the command died
after three retries. The tool was unusable against a large share of real drives.

It went deeper than the prompt. The verb API did `set -- $REQ` and validated
each word, so `mount My Backup Drive` arrived as four arguments and was
refused as an unknown volume.

This is constraint 18 wearing a different hat, and it will keep recurring: any
field that can hold a filesystem path or a volume name needs a delimiter that
cannot appear in one.

**Do:**

- Make the list **newline-delimited**, like `SOURCES` and `EXCLUDES`, and
  iterate it with `IFS` scoped to a newline.
- Every verb takes zero or one argument, so **rejoin** the request's remaining
  words into a single argument rather than validating them word by word.
- Validate that argument with `safe_arg` — the same rejected character set as
  `safe_token`, minus the space rule. Spaces become legal; `;` `&` `|` `` ` ``
  `$` `(` `)` `<` `>` `'` `"` `*` `?` `[` stay refused, and the allowlist check
  still requires an exact match against a volume the operator listed.

Widening a validator is a security change, so `safe_arg` lives in
`lib-validate.sh`, the dispatcher carries a byte-identical copy, and the test
suite fails if the two ever drift.

---

## 31. A retry loop is not self-healing — it hides the outage

**Tested:** yes — `tests/`

**Looks reasonable:** the watchdog notices a job is not running and restarts it,
every cycle, until it comes back. That is what a watchdog is for.

**Actually happens:** the underlying fault is not transient. In the reference
lab the backup volume was full, so the job failed within seconds — and the
watchdog restarted it every 15 minutes for three hours. Twelve attempts, twelve
failures.

The retries were worse than doing nothing, because each cycle reported a repair
being attempted. The estate looked *actively maintained* while it was quietly
broken, and it stayed broken for ten days.

**Do:** count consecutive failures per target and stop.

```bash
MAX_REPAIR_ATTEMPTS="${MAX_REPAIR_ATTEMPTS:-3}"
should_attempt(){ [ "$(fail_count "$1")" -lt "$MAX_REPAIR_ATTEMPTS" ]; }
```

Reset the counter when the target is observed healthy, not when the repair
command returns 0 — `launchctl` happily reports success for a job that never
starts (constraint 2). After the limit, escalate and say a human is needed:
**that message is the repair.**

**Gate every path.** Fixing only the "stale" branch left the "no snapshots at
all" branch looping forever, on a code path nobody was watching. The test
asserts both are gated, because one of them was not.

---

## 32. `ssh` inside a `while read` loop eats the loop's input

**Tested:** yes — `tests/`

**Looks reasonable:**

```bash
while IFS='|' read -r host state; do
  [ "$state" = bad ] && ssh "$HUB" "repair $host"
done < hosts.txt
```

**Actually happens:** `ssh` reads stdin, and inside that loop stdin *is*
`hosts.txt`. The first repair swallows the rest of the file, so every host after
it is silently skipped — not failed, not reported, simply absent. The run looks
clean and shorter than it should be, and the missing hosts are the ones you were
least likely to be watching.

This surfaced only because a newly added host triggered a repair on its first
cycle and the two hosts listed after it vanished from the report.

**Do:** `ssh -n` (stdin from `/dev/null`) in the command definition, so every
call site is covered rather than each one remembering `< /dev/null`. The same
trap applies to any stdin-reading command in a read-loop.

---

## 33. openrsync is a different program, and it fails differently

**Tested:** no — documented, not yet covered by a test

**Looks reasonable:** macOS ships `/usr/bin/rsync`, so use it.

**Actually happens:** it is **openrsync**, and beyond the missing flags
(constraints 8 and 27) it fails in ways GNU rsync does not.

It reads file contents with `mmap`. On a **dataless** file — one iCloud has
evicted to save space, extremely common when Desktop & Documents sync is on —
the fault handler cannot materialise the file in place and returns `EDEADLK`:

```
rsync: error: /Users/…/Book1.xlsx: mmap: Resource deadlock avoided
```

Then it does something much worse. After the resulting hangup it enters a tight
error loop, printing one line as fast as it can write:

```
rsync(6631): error: hangup awaiting block prologue: Undefined error: 0
```

Over repeated three-hour runs that produced a **164 GB log file** and consumed
160 GB of the boot volume. The backup had not completed for three days; the log
was the only thing growing.

**Do three things:**

1. **Prefer GNU rsync** where a real one is installed. It reads with `read()`,
   so a dataless file is materialised transparently instead of deadlocking.
2. **Never let a log grow unbounded.** Rotate on entry above a size cap, *and*
   collapse repeats during the run — `| uniq -c` turns a billion identical
   lines into one line and a count. Read the exit status with `PIPESTATUS[0]`,
   or you will read `uniq`'s status and treat every failed run as a success.
3. **Surface the tool's stderr.** The message named the file and the exact
   cause, and the wrapper was throwing it away — three days of "rsync exited 12"
   with the answer sitting in a discarded stream.

---

## 34. Never bless a snapshot before you have measured it, and never measure it against its predecessor

**Tested:** yes — `tests/`

A size check that runs *after* `latest` has been moved is not a check. It is a
caption on an accident that already happened.

The engine had exactly that ordering: update the symlink, then compare sizes and
warn. On a host whose backup volume had filled, one run transferred **nothing**,
exited with a status the wrapper accepted, logged

```
size check: source 615GB, snapshot 0GB (0% of source)
=== finished ===
```

and made a **zero-byte directory** the `latest` snapshot. Every run afterwards
hardlinked against that empty base, so each one had to re-send the entire ~600 GB
source from scratch, ran for hours, collided with other jobs, and failed. **The
empty snapshot caused the slowness that caused the failures.** By the time anyone
looked, **9 of 29 snapshots on that host were stubs** and the pointer everything
trusted led to a 29 MB directory.

Two rules come out of it, and the second is the one that is easy to get wrong.

**Measure before blessing.** Compute the size, decide, and only then move
`latest`. A snapshot that fails the check must leave the pointer alone and exit
non-zero, so the previous good snapshot stays both the restore point and the
hardlink base.

**Compare against a high-water mark, not the previous snapshot.** This is the
subtle half. Once a single stub has been accepted, the predecessor *is* the stub,
and a ratio test against it is worse than no test:

| baseline | new snapshot | ratio | verdict |
|---|---|---|---|
| previous snapshot = 29 MB stub | 60 GB truncated run | 2000× | **passes** |
| high-water mark of last 5 = 471 GB | 60 GB truncated run | 13% | refused |

One bad acceptance must never lower the bar for every run after it. Keep the last
few accepted sizes in a dotfile beside the snapshots and take their **max**. It
also self-heals: an obsolete mark ages out after five good runs.

**Do not use source size as the denominator.** It counts excluded trees, so it
moves for reasons that have nothing to do with backup health — deleting one
oversized log file moved it from 599 GB to 264 GB on the estate this was built
against. Keep it as a logged diagnostic and as the basis for the *inflation*
warning (constraint 12), never as the gate.

**Ship an override.** `ALLOW_SHRINK=1`, named in the rejection message. A gate
with no escape hatch turns one legitimate large deletion into a permanent silent
outage.

**Guard the bootstrap.** Establishing the *first* mark is the one moment the gate
cannot protect itself: with nothing to compare against, a thin run silently
becomes the reference and the gate is inert for the next five runs — which is
precisely how a stub history accumulates. When there is no mark yet but there is
a previous snapshot, require the new one to be at least half of it before letting
it become the reference; where a source measurement is available instead, a floor
well below the observed healthy band works as well. Log the refusal loudly: the
gate being unarmed is itself worth knowing about.

Name the dotfile so it cannot be mistaken for a snapshot: every place that
enumerates snapshots must already anchor on the timestamp pattern, never on
"everything in this directory".

## 35. Anchor date patterns on the shape of a date, not on this year

**Tested:** yes — `tests/`

The status reporter counted snapshots with `grep -c "^2026-"`. It worked
perfectly and would have reported **zero snapshots on every host** on 1 January,
which the verdict logic renders as `NO SNAPSHOTS` — a fleet-wide critical alert,
at midnight, caused by nothing. Match `^[0-9][0-9][0-9][0-9]-` instead.

## 36. A target with no `latest` is not green

**Tested:** yes — `tests/`

Related to constraint 28, but distinct and it survived that fix. Reporting
freshness from the last *completed* run is only half the job; the other half is
what to do when there has never been one.

The dashboard fell back to the newest directory when `latest` was absent, printed
an honest `no 'latest' — never completed` note beside it — and then, because that
directory was recent, coloured the row green and summed up as **ALL GREEN**. The
warning text and the verdict contradicted each other in the same output, and the
verdict is what people read.

A target with no `latest` has never produced a restorable backup. It is
**SEEDING** at best. Render it as a warning until the first run lands, however
fresh the in-progress directory looks.
