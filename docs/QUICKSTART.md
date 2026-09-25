# snapfabric quickstart

Backing up a mixed estate — a couple of Macs, a few Linux boxes, a NAS — onto one
drive, with snapshots you can browse and a restore you can prove.

This walks the whole path: install, key exchange, first fabric, and adding
machines later. Roughly 20 minutes for the first host, a couple of minutes for
each one after that.

---

## The mental model

There are two roles.

| | |
|---|---|
| **hub** | The machine with the backup drive attached. It runs the schedule and holds the keys. One per fabric. |
| **node** | A machine being backed up. Needs nothing installed but an SSH server. |

The hub **pulls** from each node on a schedule. Pull, not push, because the hub
is the one that knows whether the drive is actually mounted — and a node pushing
to a hub whose drive fell off will happily write to the hub's system disk
instead.

Each run produces a dated directory of ordinary files:

```
/Volumes/Backup Drive/fileserver/
  2026-03-01_010000/    ← a full tree, browsable, restorable with cp
  2026-03-02_010000/
  latest -> 2026-03-02_010000
```

They look like full copies and cost like incrementals: unchanged files are
hardlinks to the previous snapshot, so a hundred snapshots of a 500 GB source
occupy little more than 500 GB. No archive format, no proprietary index. If
snapfabric disappeared tomorrow your backups would still be a pile of files.

`latest` points at the last **completed** run. That distinction carries a lot of
weight — see [Why `latest` matters](#why-latest-matters).

---

## 1. Install

On the **hub**:

```bash
git clone https://github.com/christrudeau2021/snapfabric.git
cd snapfabric
./install.sh
```

Installs to `~/.local` and never asks for root. It checks bash, ssh and rsync
first and tells you what is missing.

```bash
snapfabric version
```

If that says "command not found", add `~/.local/bin` to your `PATH` — the
installer prints the exact line.

### A note on Apple's rsync

macOS 15+ ships **openrsync**, not GNU rsync. It works, with two limits worth
knowing before they bite:

- **No `--sparse`.** A sparse VM disk (`Docker.raw`, `*.qcow2`) copies at its
  full logical size. One 9.7 GB image became 926 GB in a snapshot and filled the
  drive.
- **It `mmap()`s files**, which deadlocks on iCloud placeholder files. If the
  Mac has Desktop & Documents sync on, this will eventually hang a run.

If either applies: `brew install rsync`. snapfabric prefers a real rsync
automatically when it finds one.

---

## 2. See what is out there

```bash
snapfabric discover
```

Read-only. It logs into nothing and changes nothing — it reports what responds
on your subnet and what it can infer about each address. Use it to collect the
hostnames you are about to type.

---

## 3. SSH key exchange

This is the part worth understanding rather than pasting, because it is the part
that decides how much damage a compromised hub can do.

### The problem

The hub runs unattended at 03:00, so its key to each node **cannot have a
passphrase**. And the hub holds one such key for every node — which makes the hub
a credential concentrator. If those keys granted shells, compromising the hub
would mean shell on the entire estate.

### What snapfabric does about it

One key per node, restricted at the node end to exactly one action: serving files
to rsync, read-only. `provision` does all of this for you:

1. **Generates** `~/.ssh/snapfabric_<node>` on the hub — ed25519, no passphrase.
2. **Bootstraps** one authenticated login to the node to install it. Any existing
   method works: an agent, a key you already have, or a password that **ssh
   prompts you for directly**. snapfabric never reads, stores or echoes it.
   (With `--yes` it will not prompt at all, and will fail instead — so an
   automated run cannot silently hang waiting for a human.)
3. **Installs** a forced-command wrapper and an `authorized_keys` line:

   ```
   command="~/bin/snapfabric-rsync-only",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc ssh-ed25519 AAAA… snapfabric-fileserver
   ```

   The wrapper accepts `rsync --server --sender` and refuses everything else.

4. **Verifies it empirically** — three observations, all required:

   | check | expected |
   |---|---|
   | `ssh -i key node true` | **denied** |
   | rsync read from a source path | **works** |
   | rsync write to the node | **denied** |

   A host that fails any of these is not scheduled. This step is not decoration:
   `rrsync -ro /` is a well-known "restriction" that is not one, and a forced
   command with a subtle mistake **fails open**. The only way to know a
   restriction holds is to watch it refuse something.

### What this does *not* protect

The forced command restricts the key to read-only rsync. It does **not** restrict
*which paths* it may read. The key can read anything its user can read on that
node.

**Treat each key as equivalent to read access to that account**, and give the
backup account only what it needs to read. Narrowing this per-path is worthwhile
and is not in v1. See `SECURITY.md`.

### Doing it by hand

You never have to let `provision` touch a node. To pre-authorise one yourself:

```bash
# on the hub
ssh-keygen -t ed25519 -N '' -f ~/.ssh/snapfabric_fileserver -C snapfabric-fileserver

# on the node — install the wrapper, then the restricted key line
mkdir -p ~/bin && cp /path/to/snapfabric-rsync-only.sh ~/bin/snapfabric-rsync-only
chmod 755 ~/bin/snapfabric-rsync-only
printf 'command="%s/bin/snapfabric-rsync-only",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc %s\n' \
  "$HOME" "$(cat snapfabric_fileserver.pub)" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

`provision` notices the key already works and skips its own install, so a
pre-authorised node is simply reported as done. It is idempotent either way:
re-running replaces its own line rather than appending a second one.

---

## 4. Plan the fabric

```bash
snapfabric plan
```

Interactive, and **it writes nothing but config**. No keys, no directories on the
drive, no contact with any node — except one optional read-only `df` if you ask
it to list a node's mount points for you. Nothing is provisioned until you run
the next command.

It asks about:

- **The hub itself** — the user and address `status` and `doctor` reach it by,
  the key they use (`~/.ssh/snapfabric_hub` by default, generated for you during
  `provision`), and its SSH port.
- **The drive.** Picked from a scan of what is actually mounted, so you are not
  typing a path from memory.
- **Managed volumes** — the volume names `doctor` is allowed to mount or repair.
  Anything not listed is refused, so this is an allowlist rather than a
  convenience. At least one is required.
- **Each node** — address, SSH port, what to back up, what to skip, how often.
- **Retention** — how many hourly / daily / weekly / monthly snapshots to keep.

Two questions deserve a considered answer:

**Sentinel.** If a source is a mount point, name a file inside it. An unmounted
source looks like an empty directory, and `rsync --delete` will faithfully copy
that emptiness over a good backup. With a sentinel set, the run refuses to start
instead.

**Excludes.** Name large sparse files explicitly (`Docker.raw`, `*.qcow2`) and
skip caches. Container VM disks are re-acquirable and enormous.

The result, which you can read and hand-edit:

```
~/.config/snapfabric/snapfabric.conf     the hub: drive, hosts, retention
~/.config/snapfabric/hosts/<node>.conf   one per node
```

> These are sourced as shell, so write access to either is equivalent to running
> code as you. They are mode 0600 from creation. Keep them that way.

---

## 5. Provision

```bash
snapfabric provision
```

The first command that changes anything. Per node: generate the key, install it
restricted, verify the restriction, install the agent, install the schedule.

Idempotent and resumable — every step checks whether it is already done, so
re-running after a failure continues rather than restarting. A node that fails
verification is **not scheduled**, and provisioning continues to the next one.

Preview it first if you like:

```bash
snapfabric provision --dry-run
```

### If the hub is a Mac

Two macOS-specific things, both handled, both worth knowing when something looks
inexplicable:

- **Full Disk Access.** A `launchd` job cannot write to an external volume even
  as root unless it has been granted access. Processes spawned by `sshd` inherit
  it, so the scheduled job runs via `ssh localhost`. That is why provisioning a
  Mac hub installs a loopback key.
- **Sleep.** A hub that sleeps does not back anything up:
  `sudo pmset -a sleep 0 disksleep 0`.

A Linux hub avoids all of this.

---

## 6. Prove it

```bash
snapfabric verify
```

A snapshot count proves a job ran. A green scheduler proves it was invoked.
Neither proves the bytes are there. `verify` pulls a sample of files out of a
snapshot, fetches the same files from the source, and compares SHA-256.

```
  6 files verified by SHA-256, 0 drifted, 0 failed
  restore verified
```

A source file that changed since the snapshot is drift, not failure — it is only
a failure when the two should agree and do not.

**Until `verify` has passed once, you have a copy, not a backup.**

Then, day to day:

```bash
snapfabric status
```

Exit code is the verdict — `0` green, `1` warnings, `2` needs attention — so it
can gate other automation.

---

## 7. Adding a machine later

This is the common case, and it has its own command:

```bash
snapfabric add-node
```

It asks the same questions `plan` asks about one host, then merges it into the
running fabric and offers to provision it immediately.

The merge is deliberately narrow. Only three lines of the hub config are ever
rewritten — the host list, the push list, and the staleness limits — and every
other line is passed through byte for byte. Hub-level settings like your
scheduler label prefix and retention are **read and reused, never re-asked**,
because existing schedulers are named after them and renaming a live job is
disruptive. It refuses a duplicate name, keeps a `.bak` of the previous config,
and refuses to write at all if the merge would drop a host that was there before.

```bash
snapfabric add-node --no-provision   # write the config, provision later
snapfabric add-node --replace        # rewrite an existing node's config
```

---

## Why `latest` matters

`latest` is a symlink that advances **only when a run completes**. Everything —
the dashboard, the watchdog, the next run's hardlink base — reads it rather than
"the newest directory".

The reason is a failure worth borrowing from. A dated directory is created the
moment a run *starts*, and it survives if the run dies. A monitor that reads the
newest directory therefore reports a host as fresh minutes after every failure.
On the first fabric this ran on, that hid **ten days** of failed backups behind a
green dashboard.

There is a second guard behind it. Before a run is allowed to become `latest`,
its size is compared against a high-water mark of recent good snapshots, and a
run that is drastically smaller is **refused**:

```
REFUSING to bless this snapshot: 60GB is 12% of the
  high-water mark of 471GB. A backup this much smaller than
  recent good ones did not finish. 'latest' is unchanged.
```

This also came from a real failure: a run on a full volume transferred nothing,
exited cleanly, and became `latest`. Every run after it hardlinked against an
empty base, re-sent the entire source, and failed. The empty snapshot caused the
slowness that caused the failures. If a shrink is genuine — you deleted a lot —
re-run with `ALLOW_SHRINK=1`.

---

## Keeping an eye on it

```bash
snapfabric doctor
```

Health check and self-repair: remounts volumes, restarts stopped schedulers,
triggers stale backups. It never deletes backup data.

**Run it from a machine that is not the hub.** A watchdog on the host it watches
cannot report that host being down. Any node will do — schedule it every 15
minutes there. It reaches the hub only through a restricted verb API, so it
cannot run arbitrary commands on the hub even if the watching machine is
compromised.

It backs off after three failed repair attempts on the same target rather than
retrying forever — an earlier version restarted a job every 15 minutes for three
hours against a full volume, and the retries made the outage look handled.

---

## When something is wrong

| Symptom | Cause |
|---|---|
| `no login available` on a host that works | Stale `known_hosts` entry. The host key changed; `accept-new` correctly refuses. Remove the old entry. |
| `rsync exited 255` | An **ssh** failure reported as a transfer failure. Usually a wrong port — set `SSH_PORT` in that host's config. |
| `sentinel not visible` | A source that is a mount point is not mounted. Working as intended: it refused rather than backing up an empty directory. |
| Snapshot far larger than the source | A sparse file being expanded. Find it with `du -sk <snapshot>/* \| sort -rn \| head` and exclude it. |
| `REFUSING to bless this snapshot` | The run did not finish. Check the log; `latest` is safe and unchanged. |
| Host stuck stale, no errors | It is a `push` host — the hub has no job for it. The agent must be scheduled on the host itself. |

Logs live in `~/.local/state/snapfabric/`, one file per host, on both macOS and
Linux. Override with `LOG_DIR`.

---

## The short version

```bash
./install.sh
snapfabric discover      # look around          (changes nothing)
snapfabric plan          # decide               (writes config only)
snapfabric provision     # do it
snapfabric verify        # prove it
snapfabric status        # watch it

snapfabric add-node      # add a machine later
```
