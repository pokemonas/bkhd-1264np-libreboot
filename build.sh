#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Build Libreboot for the BKHD 1264NP-12-4L (N150, 4x I226, HDMI).
#
#   ./build.sh [payloads] [vendor-dump.rom]
#
#   payloads seabios (default), grub, edk2, uboot ... or several separated by
#            commas (seabios,grub) - any payload lbmk builds for x2e_n150; the
#            ROM bin/x2e_n150/<payload>_x2e_n150*.rom is used
#   vendor   a dump of the board's original firmware (flashprog -r). With it the
#            flashable ROM out/bkhd-1264np_<payload>.rom is made; without it
#            only the base ROM (ME region blank, not flashable as is).
#
# Environment:
#   LBMK_REV   lbmk commit/tag/branch (default: the one the port was tested on)
#   LBMK_URL   default https://codeberg.org/libreboot/lbmk
#   LBMK_DIR   default ./lbmk
#   OUT        default ./out
#
# How it works: lbmk's Topton X2E N150 target ("x2e_n150", mainboard
# topton/adl) is the same SoC and the same Super I/O; this board differs in
# PCIe/clock wiring, GPIOs and display outputs. The three files in board/
# replace src/mainboard/topton/adl/{devicetree.cb,gpio.h,data_twl.vbt}, the
# target is rebuilt, and tools/ifd.py puts the vendor PCH straps + ME + HAP
# into the result.

set -eu

TESTED_REV=0513e8b5
LBMK_REV=${LBMK_REV:-$TESTED_REV}
LBMK_URL=${LBMK_URL:-https://codeberg.org/libreboot/lbmk}
HERE=$(cd "$(dirname "$0")" && pwd)
LBMK_DIR=${LBMK_DIR:-$HERE/lbmk}
OUT=${OUT:-$HERE/out}
PAYLOADS=$(echo "${1:-seabios}" | tr , ' ')
VENDOR=${2:-}
TARGET=x2e_n150
# lbmk compiles with a single job unless XBMK_THREADS is set
export XBMK_THREADS=${XBMK_THREADS:-$(nproc)}
BOARD_FILES="devicetree.cb gpio.h data_twl.vbt"

say() { printf '\n== %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" != 0 ] || die "lbmk refuses to run as root; run as a normal user"
[ -z "$VENDOR" ] || [ -f "$VENDOR" ] || die "vendor dump $VENDOR not found"
[ -z "$VENDOR" ] || VENDOR=$(cd "$(dirname "$VENDOR")" && pwd)/$(basename "$VENDOR")
git config user.name > /dev/null || die "set git config --global user.name/user.email (lbmk needs them)"

say "lbmk $LBMK_REV"
if [ ! -d "$LBMK_DIR/.git" ]; then
	git clone "$LBMK_URL" "$LBMK_DIR"
fi
cd "$LBMK_DIR"
git fetch -q origin
if git rev-parse -q --verify "origin/$LBMK_REV" > /dev/null; then
	git checkout -q --detach "origin/$LBMK_REV"
else
	git checkout -q --detach "$LBMK_REV"
fi
REV=$(git rev-parse --short=8 HEAD)
echo "lbmk at $REV ($(git log -1 --format=%cs HEAD))"

# lbmk has moved its target configs around between releases: find the one
# for $TARGET wherever it is
CFG=$(find config -path "*/$TARGET/target.cfg" 2> /dev/null | head -n 1)
if [ -z "$CFG" ]; then
	echo "lbmk layout (config/):" >&2
	find config -maxdepth 2 -type d | head -n 40 >&2
	grep -rl "$TARGET" config 2> /dev/null | head -n 20 >&2
	die "lbmk $REV: no target.cfg for $TARGET"
fi
echo "target config: $CFG"
TREE=$(sed -n 's/^tree="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$CFG" | head -n 1)
TREE=${TREE:-default}
SRC=src/coreboot/$TREE
ADL=$SRC/src/mainboard/topton/adl
echo "coreboot tree: $TREE"

say "fetch coreboot tree"
if [ ! -d "$ADL" ]; then
	# lbmk has no separate fetch command: a first build fetches the tree (and
	# builds the cross compilers), the build with the board files follows
	./mk -b coreboot "$TARGET"
fi
[ -d "$ADL" ] || die "$ADL not found after fetching"

say "board files -> $ADL"
git -C "$SRC" checkout -q -- src/mainboard/topton/adl
for f in $BOARD_FILES; do
	cp "$HERE/board/$f" "$ADL/$f"
done
git -C "$SRC" status --short -- src/mainboard/topton/adl

say "build $TARGET"
# drop what an earlier build cached for this target, so the board files are used
find elf bin -maxdepth 3 -name "*$TARGET*" -prune -exec rm -rf {} + 2> /dev/null || true
./mk -b coreboot "$TARGET"

# the board files were swapped into lbmk's tree; put lbmk's own back
git -C "$SRC" checkout -q -- src/mainboard/topton/adl

# newer lbmk packs bin/<target>/ into bin/libreboot-<ver>_<target>.tar.xz and
# removes the directory: unpack it again
if ! ls bin/$TARGET/*.rom > /dev/null 2>&1; then
	TAR=$(ls -t bin/*_${TARGET}.tar.xz 2> /dev/null | head -n 1)
	[ -n "$TAR" ] || { ls -R bin >&2; die "no ROMs and no tarball for $TARGET in bin/"; }
	echo "unpacking $TAR"
	tar xJf "$TAR" -C .
	ls bin/$TARGET/*.rom > /dev/null 2>&1 || die "$TAR has no bin/$TARGET/*.rom"
fi

mkdir -p "$OUT"
DONE=
for PAYLOAD in $PAYLOADS; do
	# lbmk up to ~26.07: one ROM per payload (seabios_x2e_n150_fspgop.rom,
	# grub_x2e_n150_fspgop_usqwerty.rom ...); newer lbmk: one ROM with all
	# payloads (edk2_grub_seabios_x2e_n150_fspgop.rom)
	ROM=
	for r in bin/$TARGET/${PAYLOAD}_${TARGET}*usqwerty*.rom bin/$TARGET/${PAYLOAD}_${TARGET}*.rom \
	    bin/$TARGET/*${PAYLOAD}*_${TARGET}*usqwerty*.rom bin/$TARGET/*${PAYLOAD}*_${TARGET}*.rom; do
		[ -f "$r" ] && { ROM=$r; break; }
	done
	[ -n "$ROM" ] || { ls "bin/$TARGET" >&2; die "no $PAYLOAD ROM in bin/$TARGET"; }
	# name the output after lbmk's payload part (seabios, edk2_grub_seabios ...)
	PAYLOAD=$(basename "$ROM" | sed "s/_${TARGET}.*//")
	case " $DONE " in *" $PAYLOAD "*) echo "$ROM already done"; continue ;; esac
	DONE="$DONE $PAYLOAD"
	echo "using $ROM"

	BASE=$OUT/bkhd-1264np_${PAYLOAD}_base.rom
	python3 "$HERE/tools/ifd.py" blank-me "$ROM" "$BASE"
	{
		echo "board=bkhd-1264np-12-4l"
		echo "payload=$PAYLOAD"
		echo "lbmk=$REV"
		echo "lbmk_rom=$(basename "$ROM")"
		echo "port=$(git -C "$HERE" rev-parse --short=8 HEAD 2> /dev/null || echo unknown)"
	} > "$OUT/bkhd-1264np_${PAYLOAD}.info"

	if [ -n "$VENDOR" ]; then
		say "hybrid with $VENDOR"
		python3 "$HERE/tools/ifd.py" hybrid "$BASE" "$VENDOR" "$OUT/bkhd-1264np_${PAYLOAD}.rom"
		python3 "$HERE/tools/ifd.py" info "$OUT/bkhd-1264np_${PAYLOAD}.rom"
		echo
		echo "flash: sudo flashprog -p internal --ifd -i bios -w $OUT/bkhd-1264np_${PAYLOAD}.rom"
		echo "       (BIOS region only; the first time from vendor firmware: see README)"
	else
		echo
		echo "$BASE: ME region blank, NOT flashable as is."
		echo "make it flashable: tools/ifd.py hybrid $BASE <vendor-dump.rom> bkhd-1264np_${PAYLOAD}.rom"
	fi
done
