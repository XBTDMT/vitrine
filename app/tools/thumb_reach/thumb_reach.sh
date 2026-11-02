#!/bin/zsh
# Finder thumbnail reach (S-18, SP-6): which types reach Vitrine's thumbnail extension on this Mac, today.
# Makes one invented file per type the extension claims (Config/uti-table.json → thumbnailExtensions), asks Finder's
# thumbnail API for each and prints the types grouped by who drew them. Writes only to a new temporary folder.
# Run from app/ with Vitrine installed: tools/thumb_reach/thumb_reach.sh [all]   ("all" adds every type Vitrine previews)
# A long-running Quick Look agent remembers earlier answers; measure after logging in again for a clean table.
# roadmap: S-18
set -e
here=${0:A:h}; work=$(mktemp -d -t vitrine-thumb-reach)
swiftc -O -o $work/thumbprobe $here/ThumbProbe.swift
swiftc -O -o $work/exts $here/Exts.swift
python3 -I - "$1" > $work/types.txt <<'PY'
import json, sys
t = json.load(open("Config/uti-table.json")); pre = t["prefix"]
types = list(t["thumbnailExtensions"]["Thumbnails"])
if sys.argv[1] == "all":
    for l in t["extensions"].values(): types += [x for x in l if x not in types and x != "public.folder"]
for x in types: print(pre + "." + x[1:] if x.startswith("$") else x)
PY
$work/exts < $work/types.txt | awk -F'\t' '$2 != ""' | sort -u -t$'\t' -k2,2 | while IFS=$'\t' read id ext; do
  printf 'invented sample %s for %s\nline two: 1\n' $RANDOM "$id" > "$work/s$RANDOM.$ext"
done
$work/thumbprobe 256 $work/s*.* | python3 -I -c '
import sys, collections
g = collections.defaultdict(list)
for line in sys.stdin:
    p = line.split()
    if not p: continue
    name, who = (p[2], p[3]) if p[0] == "type" else (p[0], p[1])
    g[who].append(name.split(".", 1)[1])
for who in ("VITRINE", "other", "none"):
    print(who.ljust(8), str(len(g[who])).rjust(3), " ".join(sorted(g[who])))'
rm -rf $work
