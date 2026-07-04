#!/bin/bash
# Produce the two sockdrive chunk-sets the Win98 install wizard consumes:
#   1. win98-setup-source.zip — FAT16-256MB image holding the CD's \WIN98 dir
#      (the CABs Setup installs from), streamed as a read-only sockdrive so the
#      ~600 MB ISO never enters memory. CONTAINS MICROSOFT CABS — never commit
#      or bundle; user-supplied media only.
#   2. win98-blank-c.zip — pre-formatted, EMPTY FAT32-2GB target. Formatting up
#      front removes FDISK/FORMAT from the wizard UX, and because mkd drops
#      all-zero ranges it chunks to ~2 files / 20 KB zipped — small enough to
#      bundle in-app as the "new blank hard drive" template.
#
# BOTH images are MBR-PARTITIONED (partition at sector 63, matching the proven
# system-win98-v1 image), NOT superfloppies: the wizard boots REAL MS-DOS 7.1
# from the startup floppy, and its IO.SYS assigns C:/D: by reading the MBR of
# fixed disks itself — a partitionless FAT volume gets no letter. (sockdrive's
# own test templates are superfloppies, which only DOSBox's internal DOS
# tolerates — don't copy that layout here.)
#
# GOTCHAS (each cost a debug cycle; all verified against real IO.SYS in Chrome):
#  - mpartition stamps partition type 0x06 (FAT16) and mformat -F does NOT
#    update it after formatting FAT32 — patch offset 0x1C2 to 0x0B (FAT32 CHS)
#    or IO.SYS misreads the target.
#  - mformat inside a partition writes BPB hidden-sectors = 0; it MUST equal
#    the partition start (63) or every FS structure is off by 63 sectors and
#    the guest faults → pass -H 63. (Geometry/totals it gets right.)
#  - Geometries must match sockdrive/drives/*.json (fat16-256mb: 489/16/63 @
#    246456 KiB; fat32-2gb: 520/128/63 @ 2097152 KiB) or mkd rejects by size.
#
# Also produced: boot-floppy.zip — a copy of sockdrive/etc/boot.img (MS-DOS 7.1
# EBD) with its AUTOEXEC.BAT replaced. The stock sockdrive floppy ends with
# `D:\scandisk.exe C: …` + an UNCONDITIONAL REBOOT.COM (the js-dos install-os
# flow's phase script) — with our drive pair that's "Bad command" + reboot
# forever. The replacement boots to a prompt and tells the user to run
# D:\WIN98\SETUP /IS (/IS skips ScanDisk, which isn't on our source root).
# KNOWN GAP: Setup's real-mode mini-GUI has no mouse without a DOS INT33
# driver on the floppy (booted Win98 has its own stack and is unaffected) —
# Setup is fully keyboard-driven meanwhile; bundle GPL CuteMouse later.
#
# Usage: make-win98-install-media.sh <Win98SE.iso> <outdir>
# Needs: 7z (p7zip), mtools (mpartition/mformat/mcopy), sockdrive release cli.
set -euo pipefail
ISO="$1"; OUT="$2"
SOCKCLI="$(cd "$(dirname "$0")/../.." && pwd)/sockdrive/target/release/cli"
mkdir -p "$OUT"; cd "$OUT"
export MTOOLSRC="$PWD/mtoolsrc"

# Extract the CD's win98/ (install CABs; ISO paths are lowercase).
7z x -y -o./iso "$ISO" win98 > /dev/null

# Source: FAT16-256MB, MBR-partitioned (type 06 is correct for big FAT16).
dd if=/dev/zero of=win98-setup-src.raw bs=1024 count=246456 2>/dev/null
echo "drive i: file=\"$PWD/win98-setup-src.raw\" partition=1" > "$MTOOLSRC"
mpartition -I i:
mpartition -c -t 489 -h 16 -s 63 i:
mformat -H 63 i:
mcopy -s iso/win98 i:/WIN98
mkdir -p src-drive && (cd src-drive && "$SOCKCLI" mkd ../win98-setup-src.raw _ drive)
(cd src-drive && zip -r -X -q ../win98-setup-source.zip drive)

# Target: FAT32-2GB, MBR-partitioned, active, formatted empty.
dd if=/dev/zero of=win98-target.raw bs=1024 count=2097152 2>/dev/null
echo "drive i: file=\"$PWD/win98-target.raw\" partition=1" > "$MTOOLSRC"
mpartition -I i:
mpartition -c -t 520 -h 128 -s 63 i:
mpartition -a i:
mformat -F -H 63 i:
printf '\x0b' | dd of=win98-target.raw bs=1 seek=$((0x1C2)) conv=notrunc 2>/dev/null
mkdir -p fmt-target-drive && (cd fmt-target-drive && "$SOCKCLI" mkd ../win98-target.raw _ drive)
(cd fmt-target-drive && zip -r -X -q ../win98-blank-c.zip drive)

# Install floppy: EBD with a prompt-first autoexec (no scandisk, no REBOOT).
BOOTIMG="$(cd "$(dirname "$SOCKCLI")/../../.." && pwd)/etc/boot.img"
[ -f "$BOOTIMG" ] || BOOTIMG="$(dirname "$SOCKCLI")/../../etc/boot.img"
cp "$BOOTIMG" boot.img
printf '@ECHO OFF\r\nset EXPAND=YES\r\nSET DIRCMD=/O:N\r\nset LglDrv=27 * 26 Z 25 Y 24 X 23 W 22 V 21 U 20 T 19 S 18 R 17 Q 16 P 15\r\nset LglDrv=%%LglDrv%% O 14 N 13 M 12 L 11 K 10 J 9 I 8 H 7 G 6 F 5 E 4 D 3 C\r\ncls\r\ncall setramd.bat %%LglDrv%%\r\nset temp=c:\\\r\nset tmp=c:\\\r\npath=%%RAMD%%:\;a:\\\r\ncopy command.com %%RAMD%%:\\ > NUL\r\nset comspec=%%RAMD%%:\\command.com\r\necho.\r\necho PocketDOS install floppy ready. C: = target, D: = install source.\r\necho Run  D:\\WIN98\\SETUP /IS  to begin Windows 98 Setup.\r\necho.\r\n' > autoexec.new
mcopy -o -i boot.img autoexec.new ::AUTOEXEC.BAT
zip -q -X boot-floppy.zip boot.img

echo "done: $OUT/win98-setup-source.zip (copyrighted, keep local) + $OUT/win98-blank-c.zip + $OUT/boot-floppy.zip"
