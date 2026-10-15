#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""
Small Intel flash descriptor helper for 16 MiB Alder Lake-N images.

  ifd.py info  <rom>                    regions, PCH strap base, HAP bit
  ifd.py blank-me <in.rom> <out.rom>    fill the ME region with 0xff
  ifd.py hybrid <base.rom> <vendor.rom> <out.rom>
        coreboot image <base.rom> + the PCH straps and ME region of the
        vendor firmware dump <vendor.rom> + HAP (PCHSTRP31 bit 16)

The "hybrid" step is what makes the BKHD 1264NP-12-4L boot: with the straps
lbmk ships for the Topton X2E N150 the board does not come up, with the
vendor straps (and the vendor ME they belong to) it does.
"""

import hashlib
import struct
import sys

IFD_SIG = 0x0FF0A55A
REGION_NAMES = ['descriptor', 'bios', 'me', 'gbe', 'pdr']
HAP_STRAP = 31
HAP_BIT = 1 << 16


def die(msg):
    sys.exit('error: ' + msg)


def load(path):
    with open(path, 'rb') as f:
        return bytearray(f.read())


def parse(img, name):
    if len(img) < 0x1000 or struct.unpack_from('<I', img, 0x10)[0] != IFD_SIG:
        die('%s: no flash descriptor signature at 0x10' % name)
    flmap0, flmap1 = struct.unpack_from('<II', img, 0x14)
    frba = ((flmap0 >> 16) & 0xff) << 4
    fpsba = ((flmap1 >> 16) & 0xff) << 4
    isl = flmap1 >> 24
    regions = {}
    for n, rname in enumerate(REGION_NAMES):
        v = struct.unpack_from('<I', img, frba + 4 * n)[0]
        base = (v & 0x7fff) << 12
        limit = (((v >> 16) & 0x7fff) << 12) | 0xfff
        if limit > base:
            regions[rname] = (base, limit)
    return {'fpsba': fpsba, 'isl': isl, 'regions': regions}


def strap(img, d, n):
    return struct.unpack_from('<I', img, d['fpsba'] + 4 * n)[0]


def is_blank(buf):
    return buf.count(0xff) == len(buf) or buf.count(0) == len(buf)


def cmd_info(path):
    img = load(path)
    d = parse(img, path)
    print('%s: %d bytes, sha256 %s' % (path, len(img), hashlib.sha256(img).hexdigest()))
    print('PCH straps at 0x%x, %d entries' % (d['fpsba'], d['isl']))
    for rname, (b, l) in d['regions'].items():
        state = ''
        if rname == 'me':
            state = ' (blank)' if is_blank(img[b:l + 1]) else ' (populated)'
        print('  %-10s 0x%07x-0x%07x%s' % (rname, b, l, state))
    if d['isl'] > HAP_STRAP:
        v = strap(img, d, HAP_STRAP)
        print('PCHSTRP%d 0x%08x, HAP %s' % (HAP_STRAP, v, 'set' if v & HAP_BIT else 'clear'))


def cmd_blank_me(src, dst):
    img = load(src)
    d = parse(img, src)
    if 'me' not in d['regions']:
        die('%s: no ME region' % src)
    b, l = d['regions']['me']
    img[b:l + 1] = b'\xff' * (l + 1 - b)
    with open(dst, 'wb') as f:
        f.write(img)
    print('%s: ME 0x%x-0x%x blanked, sha256 %s' % (dst, b, l, hashlib.sha256(img).hexdigest()))


def cmd_hybrid(base_f, vendor_f, out_f):
    base = load(base_f)
    vend = load(vendor_f)
    if len(base) != len(vend):
        die('sizes differ: %d vs %d' % (len(base), len(vend)))
    bd = parse(base, base_f)
    vd = parse(vend, vendor_f)
    print('base:   straps 0x%x/%d  ME %s' % (bd['fpsba'], bd['isl'], bd['regions'].get('me')))
    print('vendor: straps 0x%x/%d  ME %s' % (vd['fpsba'], vd['isl'], vd['regions'].get('me')))
    if (bd['fpsba'], bd['isl']) != (vd['fpsba'], vd['isl']):
        die('strap base/count differ, refusing')
    if 'me' not in bd['regions'] or bd['regions'].get('me') != vd['regions'].get('me'):
        die('ME region bounds differ, refusing')
    if bd['isl'] <= HAP_STRAP:
        die('fewer than %d straps, refusing' % (HAP_STRAP + 1))
    mb, ml = vd['regions']['me']
    if is_blank(vend[mb:ml + 1]):
        die('%s: ME region is blank - this is not a vendor firmware dump' % vendor_f)
    if b'LARCHIVE' in vend:  # CBFS file header magic
        print('warning: %s looks like a coreboot image, not the vendor firmware' % vendor_f)

    # 1) PCH straps from the vendor dump
    lo, hi = bd['fpsba'], bd['fpsba'] + 4 * bd['isl']
    for i in range(bd['isl']):
        a, b = strap(base, bd, i), strap(vend, vd, i)
        if a != b:
            print('  PCHSTRP%-2d 0x%08x -> 0x%08x' % (i, a, b))
    base[lo:hi] = vend[lo:hi]

    # 2) ME region from the vendor dump
    base[mb:ml + 1] = vend[mb:ml + 1]
    print('ME 0x%x-0x%x copied from the vendor dump' % (mb, ml))

    # 3) HAP
    o = bd['fpsba'] + 4 * HAP_STRAP
    v = struct.unpack_from('<I', base, o)[0]
    struct.pack_into('<I', base, o, v | HAP_BIT)
    print('PCHSTRP%d 0x%08x -> 0x%08x (HAP)' % (HAP_STRAP, v, v | HAP_BIT))

    with open(out_f, 'wb') as f:
        f.write(base)
    print('%s sha256 %s' % (out_f, hashlib.sha256(base).hexdigest()))


def main(argv):
    cmds = {'info': (cmd_info, 1), 'blank-me': (cmd_blank_me, 2), 'hybrid': (cmd_hybrid, 3)}
    if len(argv) < 2 or argv[1] not in cmds or len(argv) - 2 != cmds[argv[1]][1]:
        sys.exit(__doc__)
    fn, _ = cmds[argv[1]]
    fn(*argv[2:])


if __name__ == '__main__':
    main(sys.argv)
