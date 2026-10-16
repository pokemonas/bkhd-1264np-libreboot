# Libreboot for the BKHD 1264NP-12-4L

An experimental Libreboot (lbmk) port for the **BKHD 1264NP-12-4L**: an Intel
N150 (Alder Lake-N / Twin Lake) fanless box with four Intel I226 ports, HDMI
and DP, sold under various names. It is built as a variant of lbmk's
`x2e_n150` target (Topton X2E N150, coreboot mainboard `topton/adl`), which
uses the same SoC and the same ITE IT8625E Super I/O.

> Experimental. Keep a verified backup of the original firmware and an
> external SPI programmer (SOIC-8 clip + CH341A / serprog) at hand.

## Status

Tested combination (running on the author's board): lbmk `0513e8b5`
(2026-10-01), **SeaBIOS** payload, vendor straps + vendor ME + HAP, first
flash with an external programmer, Linux Mint 22.1 (Ubuntu 24.04 base) on top. This is what the CI
"tested" job builds.

| Part                    | State |
|-------------------------|-------|
| RAM init, CPU, boot     | works |
| HDMI (DDI B)            | works, also in the payload (FSP GOP) |
| DP (Type-C PHY, TC1)    | **disabled**: the TC PHY never powers up with the public TWL FSP |
| 4× I226 (RP3, RP4, RP7, RP9) | work |
| M.2 NVMe (RP12, x1)     | works, SeaBIOS boots Linux from it (Intel SSDPEKKF256G8L) |
| SATA ports 0, 1         | enabled |
| eMMC controller         | enabled (pads native as in vendor firmware) |
| Serial console          | RJ45 console port (IT8625E UART, 0x3f8); coreboot default 115200 8N1; pinout presumably Cisco-style as on the X2E – not verified |
| HAP (ME disabled after init) | works: PCHSTRP31 bit 16; MEI 00:16.0 gone, cbmem: `HECI: CSE device 16.0 is disabled`, `ME: Version: Unavailable` (coreboot itself does not hide HECI1 in this build) |
| USB 3                   | xHCI SuperSpeed root hub (10 Gb/s) present; no USB 3 device tested yet |
| Audio, sleep            | untested |

What differs from the X2E N150 (`board/vs-x2e_n150.diff`):

- **PCIe**: the NICs sit on root ports 3/4/7/9 and NVMe on 12 (X2E: 1/2/3/7,
  NVMe on 9, mPCIe on 11). The CLKREQ → clock source wiring is unknown, so
  all five clock sources are free-running and no root port claims one.
- **GPIO**: the complete pad configuration dumped with `inteltool` from the
  vendor firmware (`_PAD_CFG_STRUCT` raw values).
- **Display**: only DDI B (HDMI) enabled; VBT (`data_twl.vbt`) edited to match.
- **Flash descriptor**: the board does not come up with the PCH straps lbmk
  uses for the X2E. The flashable image therefore takes the **PCH straps and
  the ME region from a dump of the board's own vendor firmware**, and sets HAP
  (`tools/ifd.py hybrid`). Because of that, no ready-to-flash ROMs are
  published here.

## Build

On Debian/Ubuntu, as a normal user (lbmk refuses root):

```
git clone https://github.com/pokemonas/bkhd-1264np-libreboot
cd bkhd-1264np-libreboot
git config --global user.name  >/dev/null || git config --global user.name  "me"
git config --global user.email >/dev/null || git config --global user.email "me@localhost"
git clone https://codeberg.org/libreboot/lbmk
(cd lbmk && sudo ./mk dependencies ubuntu2404)   # or: debian, fedora, arch ... (see lbmk config/dependencies)

./build.sh seabios /path/to/vendor-dump.rom      # -> out/bkhd-1264np_seabios.rom
./build.sh seabios,grub /path/to/vendor-dump.rom # several payloads from one build
LBMK_REV=master ./build.sh seabios vendor.rom    # newest lbmk instead of the tested commit
```

`build.sh` checks out lbmk (`TESTED_REV` by default), fetches its coreboot
tree, copies `board/{devicetree.cb,gpio.h,data_twl.vbt}` over
`src/mainboard/topton/adl/`, builds `x2e_n150`, restores lbmk's files and then:

1. `out/bkhd-1264np_<payload>_base.rom` – lbmk's ROM with the ME region
   blanked (safe to share, **not flashable**),
2. with a vendor dump: `out/bkhd-1264np_<payload>.rom` – base + vendor PCH
   straps + vendor ME + HAP (**flashable**).

The first build takes 30–90 minutes: lbmk builds its cross compilers, and
`x2e_n150` is built twice (once to fetch the coreboot tree, once with the
board files).

lbmk naming: up to the tested commit there is one ROM per payload
(`seabios_x2e_n150_fspgop.rom`, `grub_x2e_n150_fspgop_usqwerty.rom` ...);
newer lbmk builds one ROM with all payloads
(`edk2_grub_seabios_x2e_n150_fspgop.rom`), which `build.sh` saves as
`bkhd-1264np_edk2_grub_seabios*.rom`. Only the SeaBIOS ROM of the tested
commit has been run on hardware.

### Only the hybrid step

From a CI release (base ROM) or any lbmk `x2e_n150` ROM built with the board files:

```
python3 tools/ifd.py hybrid bkhd-1264np_seabios_base.rom vendor-dump.rom bkhd-1264np_seabios.rom
python3 tools/ifd.py info bkhd-1264np_seabios.rom     # ME populated, HAP set
```

## Vendor firmware dump

Make it once, from the original firmware, before flashing anything:

```
sudo flashprog -p internal -r vendor1.rom      # Linux: boot with iomem=relaxed
sudo flashprog -p internal -r vendor2.rom
sha256sum vendor1.rom vendor2.rom               # must be identical
```

Keep it safe – it is the only way back to the vendor firmware, and every
future build needs it. Do not publish it (it contains Intel ME and the vendor
BIOS).

## Flashing

- **First time (vendor firmware → Libreboot)**: write the whole chip with an
  external programmer (SOIC-8 clip) on the chip marked SPI_ROM – not the
  LANx_ROM chips next to the NICs. Board powered off and unplugged:
  ```
  flashprog -p ch341a_spi -r before.rom             # once more, as a backup
  flashprog -p ch341a_spi -w bkhd-1264np_seabios.rom
  flashprog -p ch341a_spi -v bkhd-1264np_seabios.rom
  ```
  This is how the tested board was flashed. Internal flashing from the vendor
  firmware has not been tried.
- **Updates (Libreboot → Libreboot)**: the descriptor and ME are already in
  place, only the BIOS region changes:
  `sudo flashprog -p internal --ifd -i bios -w bkhd-1264np_seabios.rom`

- **Back to the vendor firmware / unbrick**: write the vendor dump with the
  external programmer: `flashprog -p ch341a_spi -w vendor1.rom`.

### Checking ME / HAP on the running board

```
lspci -nn -s 00:16.0                                   # no output: CSE hidden
cbmem -1 | grep -iE 'ME:|HECI|CSE'                     # cbmem from coreboot util/cbmem
```

Note on the HAP bit position: `ifd.py hybrid` sets PCHSTRP31 bit 16 (verified
above). Newer lbmk (26.10) sets PCHSTRP0 bit 16 for `x2e_n150` instead and
leaves PCHSTRP31 alone; whether that also disables the CSE on these boards is
being tested on an X2E N150.

## CI

`.github/workflows/build.yml` builds with the tested lbmk commit and with
lbmk master (weekly, and on every push). Builds of the tested commit on `main`
are attached to a release `lbmk-<rev>-<port>` (base ROMs, `.info`,
`SHA256SUMS`); master builds are kept as workflow artifacts and show early
when a new lbmk breaks the port. No vendor files are used or published by CI.

## Files

| Path | |
|------|--|
| `board/devicetree.cb`, `board/gpio.h`, `board/data_twl.vbt` | replace `src/mainboard/topton/adl/*` in lbmk's coreboot tree |
| `board/vs-x2e_n150.diff` | the same changes as a diff against lbmk's X2E files |
| `build.sh` | lbmk checkout, overlay, build, blank ME, hybrid |
| `tools/ifd.py` | `info`, `blank-me`, `hybrid` for the flash descriptor |

## License

The board files are derived from coreboot (`src/mainboard/topton/adl`):
GPL-2.0-only (`gpio.h`) / GPL-2.0-or-later (`devicetree.cb`). Scripts:
GPL-2.0-or-later.
