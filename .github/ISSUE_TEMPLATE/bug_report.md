---
name: Bug report
about: Something behaved differently from what it reported
labels: bug
---

**What happened, and what did you expect?**

**Which command?** (`plan` / `provision` / `verify` / `status` / `doctor` / `add-node`)

**Hub platform:** macOS / Linux — and `bash --version`, `rsync --version | head -1`

**Node platform(s):**

**Relevant log output.** Logs are in `~/.local/state/snapfabric/<host>.log`.
Please redact hostnames, addresses and paths you would rather not publish —
the shape of the failure is usually enough.

```
paste here
```

**Did it report success?** If something failed while claiming to work, say so
prominently. That is the failure class this project cares most about.
