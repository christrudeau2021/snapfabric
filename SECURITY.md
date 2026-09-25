# Reporting a security issue

**Please do not open a public issue for a security problem.**

Use GitHub's private vulnerability reporting — the **Security** tab → **Report a
vulnerability**. It creates a private thread visible only to the maintainer.

Expect an acknowledgement within **7 days**. This is a personal project
maintained in spare time, not a product with an on-call rota; if something is
being actively exploited, say so in the first line and I will prioritise it.

## What is in scope

Anything that lets someone read or alter backup data, or escalate access, beyond
what the design intends:

- A backup key that turns out not to be restricted to read-only rsync
- A way to make the hub's verb API run something outside its verb list, or
  accept an argument outside its allowlist
- Command injection through a config value, a host tag, a volume name, or an
  operator-typed path
- Anything that causes a snapshot to be silently accepted as good when it is not

## What is already known, and is not a vulnerability

These are documented design limits, not bugs. **[docs/SECURITY.md](docs/SECURITY.md)**
is the full threat model.

- **A backup key can read anything its user can read on that node.** The forced
  command restricts it to read-only rsync, but not to particular paths. Treat
  each key as equivalent to read access to that account.
- **The hub is a credential concentrator.** It holds a passphraseless key for
  every node, because the jobs are unattended. That is exactly why those keys
  are restricted and why the restriction is verified at provision time rather
  than assumed.
- **Backups are stored unencrypted.** The drive holds whatever the sources hold,
  including SSH keys and browser profiles. Encrypt the volume if that matters;
  snapfabric does not do it for you.
- **The config is sourced as shell.** Write access to it is equivalent to code
  execution as the operator. It is created mode 0600 and should stay that way.

If you think one of these is worse than described, that is worth reporting — the
claim, not just the mechanism.

## Reports about a specific deployment

There isn't one to report against. Nothing in this repository describes a real
network: every host, address, volume and path comes from the operator's own
config.
