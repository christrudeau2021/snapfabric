#!/bin/bash
# snapfabric — discover mount points, locally or on a remote host.
#
# Sourced by `plan` so the operator picks real filesystems from their own
# machine instead of typing paths from memory. Nothing here is specific to any
# environment: everything comes from `df` on the machine being asked.
#
# Output format, one record per line, tab-separated:
#
#   <mountpoint>\t<size>\t<use%>\t<tag>
#
# tag is one of: external | network | system | local
#
# `df -Pk` is the portable spelling — POSIX output, 1K blocks — and works the
# same on macOS and Linux. The mount point is everything from field 6 onward,
# NOT field 6: "/Volumes/My Book" is a perfectly ordinary name and taking a
# single field silently truncates it to "/Volumes/My".

# The awk program is shared between the local and remote paths so the two can
# never disagree about what counts as a real filesystem.
_SF_MOUNT_AWK='
NR == 1 { next }
{
  dev = $1
  mp = ""
  for (i = 6; i <= NF; i++) mp = mp (i > 6 ? " " : "") $i
  if (mp == "") next

  # Pseudo and virtual filesystems: never backup sources, only noise.
  if (dev ~ /^(devfs|map|tmpfs|devtmpfs|none|overlay|udev|sysfs|proc|squashfs|efivarfs|ramfs)$/) next
  if (dev ~ /^map /) next
  if (mp ~ /^\/(proc|sys|run|dev)(\/|$)/) next
  if (mp ~ /^\/System\/Volumes\/(VM|Preboot|Update|xarts|iSCPreboot|Hardware|Recovery)/) next
  if (mp ~ /^\/private\/var\/vm/) next
  if (mp ~ /^\/snap\//) next

  # Backup machinery mounted as filesystems. On a Mac with Time Machine running,
  # these are the overwhelming majority of df output -- 23 of 26 entries on the
  # first machine this was tried against -- and not one of them is something a
  # person would ever choose to back up. A menu that long is the same as no menu.
  if (mp ~ /com\.apple\.TimeMachine/) next
  if (mp ~ /Backups\.backupdb/) next
  if (mp ~ /\.backup$/) next
  if (mp ~ /\/\.[^\/]+(\/|$)/) next        # any hidden path component, e.g. /Volumes/.timemachine
  if (mp ~ /^\/var\/lib\/docker/) next      # overlay mounts, one per container layer

  size = $2; used = $3; cap = $5
  gsub("%", "", cap)

  tag = "local"
  if (dev ~ /^\/\// || dev ~ /:/)                 tag = "network"
  else if (mp ~ /^\/Volumes\// ||
           mp ~ /^\/mnt\//     ||
           mp ~ /^\/media\//)                     tag = "external"
  else if (mp == "/" || mp == "/System/Volumes/Data") tag = "system"

  # Human size from 1K blocks, computed here so both paths format identically.
  s = size
  unit = "K"
  if (s >= 1048576) { s = s / 1048576; unit = "G" }
  else if (s >= 1024) { s = s / 1024; unit = "M" }
  if (s >= 1024 && unit == "G") { s = s / 1024; unit = "T" }

  prio = 4
  if (tag == "external") prio = 1
  else if (tag == "local") prio = 2
  else if (tag == "network") prio = 3
  printf "%d\t%s\t%.0f%s\t%s%%\t%s\n", prio, mp, s, unit, cap, tag
}'

# External drives first: on a backup tool, that is what the operator is almost
# always reaching for. System disks last, since choosing one is usually a mistake.
# Priority first, then mount point alphabetically under LC_ALL=C. The secondary
# key is not cosmetic: sort is not stable, so without it two external drives
# came back in an arbitrary order and the menu numbering changed between runs.
# An operator picking "1" must get the same filesystem every time.
_sf_order(){ LC_ALL=C sort -t"$(printf '\t')" -k1,1n -k2,2 | cut -f2-; }

# Parse `df -Pk` output arriving on stdin. Factored out so the filtering can be
# tested against synthetic df output without needing the filesystems to exist.
scan_mounts_parse(){ awk "$_SF_MOUNT_AWK" | _sf_order; }

scan_mounts_local(){
  df -Pk 2>/dev/null | scan_mounts_parse
}

# scan_mounts_remote <ssh-command> <user@host>
# Read-only: it runs `df -Pk` and nothing else. Returns non-zero (and prints
# nothing) if the host cannot be reached or refuses the command -- callers must
# fall back to asking the operator to type paths rather than treating an empty
# list as "this host has no filesystems".
scan_mounts_remote(){
  local sshcmd="$1" target="$2" out
  out=$($sshcmd "$target" 'df -Pk' 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | scan_mounts_parse
}

# Render a numbered menu from scan output on stdin. Writes the menu to stdout
# and the raw mountpoints, one per line, to the file named in $1 so the caller
# can resolve a number back to a path.
render_mount_menu(){
  local indexfile="$1" i=0 mp size cap tag
  : > "$indexfile"
  while IFS=$'\t' read -r mp size cap tag; do
    [ -n "$mp" ] || continue
    i=$((i + 1))
    printf '%s\n' "$mp" >> "$indexfile"
    case "$tag" in
      external) mark="external drive" ;;
      network)  mark="network share" ;;
      system)   mark="system disk" ;;
      *)        mark="" ;;
    esac
    printf '      %2d) %-38s %6s  %4s used  %s\n' "$i" "$mp" "$size" "$cap" "$mark"
  done
  [ "$i" -gt 0 ]
}

# Resolve an operator answer to a path: a number picks from the menu index, and
# anything else is taken literally so typing a path always still works.
resolve_mount_choice(){ # resolve_mount_choice <indexfile> <answer>
  local idx="$1" ans="$2"
  case "$ans" in
    ''|*[!0-9]*) printf '%s' "$ans" ;;
    *) sed -n "${ans}p" "$idx" 2>/dev/null ;;
  esac
}
