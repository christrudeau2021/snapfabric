# Design notes

Why snapfabric is shaped the way it is. The failures behind individual rules are
in [`CONSTRAINTS.md`](CONSTRAINTS.md); this is the level above that.

---

## Hardlinked rsync snapshots, not an archive format

borg and restic are better at deduplication and they encrypt. snapfabric writes
plain directory trees instead, because of what happens on the worst day.

A hardlinked snapshot is a full tree of ordinary files. You restore with `cp`.
You browse it in Finder. You check it with `shasum`. If this project is
abandoned, or its author is unreachable, or the version that wrote the backup no
longer builds, **the backup is still just files**. An archive format makes the
restore path depend on software continuing to exist and continuing to work — and
the moment you need a restore is the moment you least want a second dependency.

The cost is real and worth stating: no deduplication across dissimilar files, no
encryption at rest, and a snapshot count bounded by inodes rather than by clever
packing. For a home or small-office estate on a single drive, that trade has
been worth it.

## Pull, not push

The hub reaches out to each node on a schedule; nodes do not send.

The hub is the only machine that knows whether the backup drive is actually
mounted. A node pushing into a hub whose drive fell off will write happily into
the mount point — an ordinary directory on the boot volume — and fill it. Pull
also means a compromised node cannot reach into the backup store, which matters
because the store holds every *other* node's data too.

Push hosts are supported for the cases pull cannot reach (a laptop that is
rarely up, a host behind NAT), and they are explicitly modelled: the hub has no
scheduler for them, and `status` says so rather than reporting them stale
forever.

## Shell, and no runtime

bash 3.2, ssh, rsync, coreutils. Nothing else.

A backup agent has to work on a machine that has just been rebuilt, and every
dependency is a thing that can be missing or wrong at exactly that moment. On
macOS `/usr/bin/python3` is a stub that triggers an Xcode Command Line Tools
prompt — so a Python agent does not fail cleanly on a fresh Mac, it fails by
opening a dialog box on a headless machine.

bash 3.2 rather than 4+ for the same reason: it is what macOS ships. That costs
associative arrays, `mapfile`, and nameref locals, and it is still the right
constraint.

## The interesting part is noticing failure, not copying files

Copying files is `rsync -a`. Most of this codebase is the other thing.

The recurring failure in backup systems is not "the copy went wrong" — it is
"the copy stopped happening and the dashboard stayed green." Every mechanism
here exists because that happened:

- **`latest` only advances on a completed run.** A dated directory exists from
  the moment a run *starts* and survives if it dies, so a monitor reading "the
  newest directory" reports freshness minutes after every failure.
- **A snapshot is measured before it is blessed**, against a high-water mark of
  recent good runs, because a run that transferred nothing once became `latest`
  and every subsequent run hardlinked against an empty base.
- **A restore is performed, not inferred.** `verify` pulls files back out and
  compares SHA-256. A snapshot count proves a job ran; a green scheduler proves
  it was invoked; neither proves the bytes are there.
- **Restrictions are measured, not declared.** `provision` refuses to schedule a
  host until it has watched that host deny a shell and deny a write.
- **A sentinel guards mount points**, because an unmounted source looks like an
  empty directory and `--delete` will faithfully copy that emptiness over a good
  backup.

The tests follow the same rule, and it is not decorative: several of them passed
while exercising nothing until they were deliberately broken to check they could
fail.

## Config is shell, not YAML

`plan` writes the same `snapfabric.conf` the agents already source. A YAML file
would need a parser in every agent — a runtime dependency in the one place this
project has worked hardest not to have one — to serve a file nothing else reads.

The consequence is stated rather than hidden: the config is executed, so write
access to it is equivalent to code execution as the operator. It is created mode
0600, every operator-typed value is validated before it is written, and there is
a test that pasting a `$(…)` into a prompt does not produce a config that runs
it.

## Platform support, honestly

**The hub is macOS today.** The verb API that `status` and `doctor` speak to the
hub through is built on `diskutil` and `launchctl`. A Linux hub can run the
snapshot engine and be provisioned, but it has no equivalent of that API, so
health reporting and self-repair do not work there yet.

**Nodes are any OS** with ssh and bash.

This is narrower than the original intent, and it is written down rather than
implied. A Linux hub is the largest open piece of work.

## Not in scope

- **Encryption at rest.** The drive holds whatever the sources hold, in the
  clear. Use an encrypted volume if that matters; the choice has to be made when
  the volume is created, which is why it is called out in `SECURITY.md`.
- **Offsite replication.** Out of scope, deliberately: it changes the threat
  model substantially and there are good dedicated tools for it.
- **Automated Time Machine setup.** `status` and `doctor` can watch a Time
  Machine advertiser you configured yourself, and that is all.
- **A web UI.**
