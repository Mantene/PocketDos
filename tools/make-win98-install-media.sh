#!/bin/bash
# Produce the two sockdrive chunk-sets the Win98 install wizard consumes:
#   1. win98-setup-source.zip — FAT16-256MB superfloppy holding the CD's \WIN98
#      dir (the CABs Setup installs from), streamed as a read-only sockdrive so
#      the ~600 MB ISO never enters memory. CONTAINS MICROSOFT CABS — never
#      commit or bundle; user-supplied media only.
#   2. win98-blank-c.zip — pre-formatted, EMPTY FAT32-2GB target. Formatting
#      up front removes FDISK/FORMAT from the wizard UX, and because mkd drops
#      all-zero ranges it chunks to ~552 KB (boot sector + FATs) — small enough
#      to bundle in-app as the "new blank hard drive" template.
#
# Superfloppy layout (no MBR) is deliberate: it matches sockdrive's own drive
# templates (see sockdrive/test-assets/generate.sh, which runs mkfs.fat straight
# on the raw), and the geometries MUST match sockdrive/drives/*.json exactly or
# `cli mkd` rejects the image by size.
#
# Usage: make-win98-install-media.sh <Win98SE.iso> <outdir>
# Needs: 7z (p7zip), mtools (mformat/mcopy), and the sockdrive repo's release cli.
set -euo pipefail
ISO="$1"; OUT="$2"
SOCKCLI="$(dirname "$0")/../../sockdrive/target/release/cli"
mkdir -p "$OUT"; cd "$OUT"

# Extract the CD's win98/ (install CABs; ISO paths are lowercase).
7z x -y -o./iso "$ISO" win98 > /dev/null

# Source: FAT16-256MB superfloppy, geometry from sockdrive/drives/fat16-256mb.json
# (489 cyl x 16 heads x 63 spt x 512 = 246456 KiB exactly).
dd if=/dev/zero of=win98-setup-src.raw bs=1024 count=246456 2>/dev/null
mformat -i win98-setup-src.raw -t 489 -h 16 -s 63 ::
mcopy -i win98-setup-src.raw -s iso/win98 ::/WIN98
mkdir -p src-drive && (cd src-drive && "$SOCKCLI" mkd ../win98-setup-src.raw _ drive)
(cd src-drive && zip -r -X -q ../win98-setup-source.zip drive)

# Target: FAT32-2GB superfloppy, formatted empty, geometry from fat32-2gb.json
# (520 x 128 x 63; file must be exactly 2097152 KiB for mkd's template match).
dd if=/dev/zero of=win98-target.raw bs=1024 count=2097152 2>/dev/null
mformat -i win98-target.raw -F -t 520 -h 128 -s 63 ::
mkdir -p fmt-target-drive && (cd fmt-target-drive && "$SOCKCLI" mkd ../win98-target.raw _ drive)
(cd fmt-target-drive && zip -r -X -q ../win98-blank-c.zip drive)

echo "done: $OUT/win98-setup-source.zip (copyrighted, keep local) + $OUT/win98-blank-c.zip"
