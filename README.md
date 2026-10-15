# Libreboot for the BKHD 1264NP-12-4L

An experimental Libreboot (lbmk) port for the **BKHD 1264NP-12-4L**: an Intel
N150 (Alder Lake-N / Twin Lake) fanless box with four Intel I226 ports, HDMI
and DP, sold under various names. It is built as a variant of lbmk's
`x2e_n150` target (Topton X2E N150, coreboot mainboard `topton/adl`), which
uses the same SoC and the same ITE IT8625E Super I/O.

> Experimental. Keep a verified backup of the original firmware and an
> external SPI programmer (SOIC-8 clip + CH341A / serprog) at hand.

## Status

| Part                    | State |
|-------------------------|-------|
| RAM init, CPU, boot     | works |
| HDMI (DDI B)            | works, also in the payload (FSP GOP) |
| DP (Type-C PHY, TC1)    | **disabled**: the TC PHY never powers up with the public TWL FSP |
| 4× I226 (RP3, RP4, RP7, RP9) | work |
| M.2 NVMe (RP12, x1)     | enabled |
| SATA ports 0, 1         | enabled |
| eMMC controller         | enabled (pads native as in vendor firmware) |
| Serial console          | IT8625E UART at 0x3f8 |
| HAP (ME disabled after init) | set (PCHSTRP31 bit 16) |
| USB 3, audio, sleep     | untested |

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
git clone https://github.com/OWNER/bkhd-1264np-libreboot
cd bkhd-1264np-libreboot
git config --global user.name  >/dev/null || git config --global user.name  "me"
git config --global user.email >/dev/null || git config --global user.email "me@localhost"
git clone https://codeberg.org/libreboot/lbmk && (cd lbmk && sudo ./mk dependencies debian)

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

The first build takes 30–90 minutes (lbmk builds its cross compilers).

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

- **First time (vendor firmware → Libreboot)**: write the whole chip,
  preferably with an external programmer on the SOIC-8 chip marked SPI_ROM
  (not the LANx_ROM chips next to the NICs):
  `flashprog -p ch341a_spi -w bkhd-1264np_seabios.rom` (read back and compare).
  Internal `flashprog -p internal -w …` works only if the vendor descriptor
  leaves the regions writable.
- **Updates (Libreboot → Libreboot)**: the descriptor and ME are already in
  place, only the BIOS region changes:
  `sudo flashprog -p internal --ifd -i bios -w bkhd-1264np_seabios.rom`

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
