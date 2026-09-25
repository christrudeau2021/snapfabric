# snapfabric

Hardlinked rsync snapshots across a mixed estate — Macs, Linux boxes, a NAS —
onto one drive, with a restore you can prove.

```bash
./install.sh
snapfabric plan          # design it      (writes config only)
snapfabric provision     # build it
snapfabric verify        # prove it
snapfabric status        # watch it
```

**[Start here: docs/QUICKSTART.md](docs/QUICKSTART.md)** — install, SSH key
exchange, first fabric, adding machines later.

---

## What it is

A hub with a drive pulls each node over SSH on a schedule and writes a dated
snapshot. Unchanged files are hardlinks to the previous snapshot, so a hundred
snapshots of a 500 GB source cost little more than 500 GB.

```
/Volumes/Backup Drive/fileserver/
  2026-03-01_010000/    ← a full tree, browsable, restorable with cp
  2026-03-02_010000/
  latest -> 2026-03-02_010000
```

No archive format and no index. If this project vanished, your backups would
still be a pile of ordinary files.

## Why another one

Because the interesting part of a backup system is not copying files — it is
noticing when it has stopped working. Most of the code here is about that:

- **`latest` only advances on a completed run.** Everything reads it. A dated
  directory exists from the moment a run *starts*, so a monitor watching "the
  newest directory" reports success minutes after every failure. That hid ten
  days of failed backups behind a green dashboard.
- **A snapshot is measured before it is blessed**, against a high-water mark of
  recent good runs. A run that transferred nothing once became `latest`; every
  run after it hardlinked against an empty base and failed.
- **A restore is performed, not assumed.** `verify` pulls files back out and
  compares SHA-256. Until it passes, you have a copy.
- **Restrictions are tested, not declared.** Each key is proven to be denied a
  shell and denied writes before its host is scheduled.
- **A sentinel file guards mount points.** An unmounted source looks like an
  empty directory, and `--delete` will copy that emptiness over a good backup.

Every one of those traces to a specific failure. They are written up and
numbered in **[docs/CONSTRAINTS.md](docs/CONSTRAINTS.md)**, and each one says
whether a test enforces it — 20 of 36 do today, and the document marks which,
because a claim you cannot check is worth less than an honest gap.

Design rationale — why hardlinks, why pull, why shell, and what is deliberately
out of scope — is in **[docs/DESIGN.md](docs/DESIGN.md)**.

## Requirements

bash 3.2+, ssh, rsync. **No Python, no runtime, no daemon.**

**The hub is macOS today.** A Linux hub runs the snapshot engine and provisions
fine, but the verb API that `status` and `doctor` use is built on `diskutil` and
`launchctl`, so health reporting and self-repair do not work there yet. That is
the largest open piece of work.

**Nodes are any OS** with an SSH server and bash — `provision` runs a short
script there to install the restricted key and its forced command.

On macOS 15+, prefer GNU rsync (`brew install rsync`); Apple's openrsync has no
`--sparse` and deadlocks on iCloud placeholder files. The installer checks and
tells you.

## Security posture

The hub holds a passphraseless key for every node, which makes it a credential
concentrator. Each key is restricted at the node end by a forced command to
read-only rsync, verified empirically at provision time.

That restriction does **not** limit which paths the key may read — treat each key
as equivalent to read access to that account. Backups are stored unencrypted.
**[docs/SECURITY.md](docs/SECURITY.md)**.

## Commands

| | |
|---|---|
| `discover` | find candidate hosts *(read-only)* |
| `plan` | design the fabric *(writes config only)* |
| `add-node` | onboard one host into a live fabric |
| `provision` | install keys, agents, schedules |
| `verify` | prove a restore by doing one *(read-only)* |
| `status` | one-screen health report *(read-only)* |
| `doctor` | health check and self-repair; run from a non-hub machine |

## Tests

```bash
tests/test-constraints.sh    # offline: one test per documented constraint
tests/test-provision.sh      # against a throwaway sshd on a high port
```

The integration suite stands up a real `sshd` as the current user in a temp
directory — no sudo, no change to your `authorized_keys`, no host on the network
contacted. It reports SKIPPED rather than passing if it cannot start one.

## Status

v1.0.0. Running unattended on a small mixed estate, and soaked for two weeks
before this was published — `status` green and `verify` passing for every host.

It is young, and it is one person's project. The parts most likely to bite you
first: a Linux hub (see Requirements), and the sixteen constraints in
`docs/CONSTRAINTS.md` that are documented but not yet enforced by a test.
