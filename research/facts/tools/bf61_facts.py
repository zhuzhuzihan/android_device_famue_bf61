#!/usr/bin/env python3
"""BF61 fact extractor -- reproduces every number quoted in research/facts/device-facts.md.

Read-only against the stock dumps; writes nothing. Extends the Lead's tools/fdt.py
(imported, not modified) with boot-header / DTBO-container / AVB parsing.

Usage:
    python3 bf61_facts.py [--backup /sdcard/bf61_backup] [--repo /root/android_device_famue_bf61]
"""
import argparse, binascii, gzip, hashlib, io, os, struct, sys

FDT_TOOLS = '/root/work/bf61/tools'
if FDT_TOOLS not in sys.path:
    sys.path.insert(0, FDT_TOOLS)
import fdt  # noqa: E402  (Lead's parser)

U32 = lambda d, o: struct.unpack_from('<I', d, o)[0]
U64 = lambda d, o: struct.unpack_from('<Q', d, o)[0]
B32 = lambda d, o: struct.unpack_from('>I', d, o)[0]

def sha256(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()

# ---------------------------------------------------------------- boot header v2
BOOT_FIELDS = [
    ('kernel_size', 0x008, 4), ('kernel_addr', 0x00c, 4),
    ('ramdisk_size', 0x010, 4), ('ramdisk_addr', 0x014, 4),
    ('second_size', 0x018, 4), ('second_addr', 0x01c, 4),
    ('tags_addr', 0x020, 4), ('page_size', 0x024, 4),
    ('header_version', 0x028, 4), ('os_version', 0x02c, 4),
    ('recovery_dtbo_size', 0x660, 4), ('recovery_dtbo_offset', 0x664, 8),
    ('header_size', 0x66c, 4), ('dtb_size', 0x670, 4), ('dtb_addr', 0x674, 8),
]

def parse_boot(path):
    d = open(path, 'rb').read()
    if d[:8] != b'ANDROID!':
        return {'error': 'no ANDROID! magic', 'path': path}
    info = {'path': path, 'size': len(d), 'magic': d[:8].decode()}
    for name, off, size in BOOT_FIELDS:
        info[name] = U32(d, off) if size == 4 else U64(d, off)
    info['name_field'] = d[0x30:0x40]
    info['cmdline'] = d[0x40:0x240].split(b'\0')[0].decode()
    info['extra_cmdline'] = d[0x260:0x260 + 1024].split(b'\0')[0].decode()
    info['id_field'] = d[0x240:0x260]
    pg, ks, rs, ss, ds = (info['page_size'], info['kernel_size'], info['ramdisk_size'],
                          info['second_size'], info['dtb_size'])
    pages = lambda n: (n + pg - 1) // pg
    off = pg
    info['segments'] = {}
    for label, size in (('kernel', ks), ('ramdisk', rs), ('second', ss), ('dtb', ds)):
        info['segments'][label] = (off, size)
        off += pages(size) * pg
    ko, _ = info['segments']['kernel']; ro, _ = info['segments']['ramdisk']
    info['kernel'] = d[ko:ko + ks]
    info['ramdisk'] = d[ro:ro + rs]
    do, _ = info['segments']['dtb']
    info['dtb'] = d[do:do + ds]
    # AOSP 12.1 mkbootimg im_id = sha1(kernel,ksize, ramdisk,rsize, second* , recovery_dtbo*, dtb, dsize)
    h = hashlib.sha1()
    for part in (info['kernel'], ks, info['ramdisk'], rs, ss, info['recovery_dtbo_size'], info['dtb'], ds):
        h.update(part if isinstance(part, bytes) else struct.pack('<I', part))
    info['id_calc_aosp'] = h.digest()
    v = info['os_version']
    info['os'] = ((v >> 25) & 0x7f, (v >> 11) & 0x7f, (v >> 4) & 0x7f, v & 0xf)
    info['base'] = info['kernel_addr'] - U32(d, 0)
    return info

# --------------------------------------------------------- dt_table (dtbo) parser
def parse_dt_table(blob):
    if blob[:4] != b'\xd7\xb7\xab\x1e':
        return None
    magic, total, hsz, esz, cnt, eoff, psz, ver = struct.unpack_from('>8I', blob, 0)
    entries = []
    for i in range(cnt):
        o = eoff + i * esz
        dsz, doff, did, rev = struct.unpack_from('>4I', blob, o)
        entries.append({'dt_size': dsz, 'dt_offset': doff, 'id': did, 'rev': rev,
                        'custom': blob[o + 16:o + esz]})
    return {'magic': magic, 'total_size': total, 'header_size': hsz, 'entry_size': esz,
            'entry_count': cnt, 'entries_offset': eoff, 'page_size': psz,
            'version': ver, 'entries': entries}

def avb_footer(blob):
    i = len(blob) - 64
    if blob[i:i + 4] != b'AVBf':
        return None
    maj, minor = struct.unpack_from('>II', blob, i + 4)
    orig, = struct.unpack_from('>Q', blob, i + 12)
    vboff, = struct.unpack_from('>Q', blob, i + 20)
    vbsz, = struct.unpack_from('>Q', blob, i + 28)
    return {'version': f'{maj}.{minor}', 'original_image_size': orig,
            'vbmeta_offset': vboff, 'vbmeta_size': vbsz,
            'vbmeta_magic': blob[vboff:vboff + 16].hex()}

def fdt_nodes(blob, container_ok=True):
    if container_ok and blob[:4] == b'\xd7\xb7\xab\x1e':
        t = parse_dt_table(blob)
        e = t['entries'][0]
        blob = blob[e['dt_offset']:e['dt_offset'] + e['dt_size']]
    return fdt.parse(blob)

# ------------------------------------------------------------------------ report
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--backup', default='/sdcard/bf61_backup')
    ap.add_argument('--repo', default='/root/android_device_famue_bf61')
    a = ap.parse_args()

    print('=' * 78, '\n1) BOOT HEADER\n' + '=' * 78)
    for name in ('boot_a', 'boot_b', 'boot_working'):
        p = os.path.join(a.backup, name + '.img')
        i = parse_boot(p)
        print(f'\n-- {name}.img  ({i.get("size")} bytes) sha256={sha256(p)}')
        if 'error' in i:
            print('   ', i['error'], '| all-zero:', not any(open(p, 'rb').read()))
            continue
        for k in ('page_size', 'header_size', 'header_version', 'os_version', 'kernel_size',
                  'kernel_addr', 'ramdisk_size', 'ramdisk_addr', 'second_size', 'second_addr',
                  'tags_addr', 'dtb_size', 'dtb_addr', 'recovery_dtbo_size'):
            print(f'   {k:20s} = 0x{i[k]:x} ({i[k]})')
        print(f'   os decode (ver,patch,year,month) = {i["os"]}')
        print(f'   cmdline            = {i["cmdline"]!r}')
        print(f'   extra_cmdline      = {i["extra_cmdline"]!r}')
        print(f'   name/board field   = {i["name_field"].hex()}')
        print(f'   segments           = { {k: (hex(o), s) for k, (o, s) in i["segments"].items()} }')
        print(f'   id sha1 recompute  = {i["id_calc_aosp"].hex()}  header={i["id_field"][:20].hex()}'
              f'  {"MATCH" if i["id_calc_aosp"] == i["id_field"][:20] else "MISMATCH"}')
        for label in ('kernel', 'ramdisk'):
            blob = i[label]
            ok = blob[:2] == b'\x1f\x8b'
            out = b''
            if ok:
                try:
                    out = gzip.decompress(blob)
                except Exception as e:                                    # noqa: BLE001
                    out = b''
            print(f'   {label}: gzip={ok} raw_len={len(out)}')

    print('\n-- kernel/dtb vs repo prebuilts')
    for name, rel in (('boot_a.kernel', 'prebuilt/kernel'), ('boot_a.dtb', 'prebuilt/dtb.img'),
                      ('boot_working.kernel', 'prebuilt/kernel')):
        st = os.path.join('/root/work/bf61/stock', name)
        rp = os.path.join(a.repo, rel)
        if os.path.exists(st) and os.path.exists(rp):
            print(f'   {name} {sha256(st)[:16]}  vs {rel} {sha256(rp)[:16]} '
                  f'{"IDENTICAL" if sha256(st) == sha256(rp) else "DIFFERS"}')

    print('\n' + '=' * 78, '\n2/3) DTB (boot) + DTBO (partition)\n' + '=' * 78)
    ba = parse_boot(os.path.join(a.backup, 'boot_a.img'))
    t = parse_dt_table(ba['dtb'])
    print('boot dtb section -> dt_table:', {k: (hex(v) if k == 'magic' else v)
                                            for k, v in t.items() if k != 'entries'},
          '\n  entries:', t['entries'])
    nodes = fdt_nodes(ba['dtb'])
    for n in nodes:
        if n['path'] in ('/', '/chosen'):
            for k, v in n['props'].items():
                if k == 'model':
                    print(f"  {n['path']} model = {v.split(b'\\0')[0].decode()!r}")
                if k == 'compatible':
                    print(f"  {n['path']} compatible = {v.replace(b'\\0', b',').decode()!r}")
                if k == 'bootargs':
                    print(f"  {n['path']} bootargs = {v.split(b'\\0')[0].decode()!r}")
    print('  node count:', len(nodes), '| nodes of interest:',
          [n['path'] for n in nodes if any(s in n['path'] for s in
           ('touch', 'usb0', 'msdc', 'mtkfb', 'i2c0@', 'i2c4@'))])

    for name in ('dtbo_a', 'dtbo_b'):
        p = os.path.join(a.backup, name + '.img')
        blob = open(p, 'rb').read()
        tt = parse_dt_table(blob)
        print(f'\n-- {name}.img size={len(blob)} sha256={sha256(p)}')
        print('   dt_table:', None if not tt else
              {k: (hex(v) if k == 'magic' else v) for k, v in tt.items() if k != 'entries'},
              '\n   entries:', None if not tt else tt['entries'])
        print('   avb footer:', avb_footer(blob))
        if tt:
            ov = blob[tt['entries'][0]['dt_offset']:][:tt['entries'][0]['dt_size']]
            onodes = fdt.parse(ov)
            fx = {n['path']: n for n in onodes}
            for n in onodes:
                if n['path'] in ('/__fixups__',):
                    print('   __fixups__ (target labels):',
                          {k: v.replace(b'\0', b' ').decode()[:60] for k, v in n['props'].items()})
                if 'cap_touch' in n['path']:
                    print('  ', n['path'], {k: v.hex() for k, v in n['props'].items()})
    art = os.path.join(a.repo, 'research/artifacts/dtbo.img')
    if os.path.exists(art):
        blob = open(art, 'rb').read()
        print(f'\n-- trimmed artifact {art} size={len(blob)} sha256={sha256(art)}')
        print('   reparses:', parse_dt_table(blob) is not None)

    print('\n' + '=' * 78, '\n4) VENDOR_BOOT / VBMETA\n' + '=' * 78)
    for name in ('vendor_boot_a', 'vendor_boot_b'):
        p = os.path.join(a.backup, name + '.img')
        blob = open(p, 'rb').read()
        print(f'-- {name}.img size={len(blob)} first8={blob[:8]!r} all_zero={not any(blob)}')
    for name in ('vbmeta_a', 'vbmeta_b', 'vbmeta_system_a', 'vbmeta_system_b',
                 'vbmeta_vendor_a', 'vbmeta_vendor_b'):
        p = os.path.join(a.backup, name + '.img')
        blob = open(p, 'rb').read()
        if blob[:4] != b'AVB0':
            print(f'-- {name}: no AVB0 magic, all_zero={not any(blob)} size={len(blob)}')
            continue
        auth, = struct.unpack_from('>Q', blob, 12)
        dsz, = struct.unpack_from('>Q', blob, 104)
        flags, rbil = struct.unpack_from('>II', blob, 120)
        rel = blob[128:176].split(b'\0')[0].decode()
        print(f'-- {name}: AVB0 flags=0x{flags:x} (1=hashtree_disabled,2=verification_disabled)'
              f' rollback_loc={rbil} release={rel!r}')
        off, end = 256 + auth, 256 + auth + dsz
        while off < end:
            tag, nb = struct.unpack_from('>QQ', blob, off)
            b = blob[off + 16:off + 16 + nb]
            if tag == 4:      # chain
                rb, pnl, pkl, fl = struct.unpack_from('>IIII', b, 0)
                print(f'   CHAIN      {b[76:76+pnl].split(b"\0")[0].decode():14s} rollback_loc={rb}')
            elif tag == 2:    # hash
                sz, = struct.unpack_from('>Q', b, 0)
                pnl, sl, dl, fl = struct.unpack_from('>IIII', b, 40)
                print(f'   HASH       {b[116:116+pnl].split(b"\0")[0].decode():14s} image_size={sz}')
            elif tag == 1:    # hashtree
                dmv, sz = struct.unpack_from('>QQ', b, 0)
                pnl, sl, dl, fl = struct.unpack_from('>IIII', b, 48)
                print(f'   HASHTREE   {b[128:128+pnl].split(b"\0")[0].decode():14s} image_size={sz}')
            elif tag == 0:    # property
                kl, vl = struct.unpack_from('>QQ', b, 0)
                print(f'   PROPERTY   {b[16:16+kl].split(b"\0")[0].decode()}'
                      f' = {b[16+kl:16+kl+vl][:44].decode("ascii", "replace")!r}')
            off += (16 + nb + 7) & ~7

    print('\n' + '=' * 78, '\n5/6) STOCK RAMDISK FACTS\n' + '=' * 78)
    rd = '/root/work/bf61/rd_stock'
    for f in ('init.recovery.mt6762.rc', 'init.recovery.mt6765.rc'):
        p = os.path.join(rd, f)
        print(f'   {f}: exists={os.path.exists(p)} sha256={sha256(p)[:16] if os.path.exists(p) else "-"}')
    for f in ('first_stage_ramdisk/fstab.mt6762', 'first_stage_ramdisk/fstab.mt6765',
              'system/etc/recovery.fstab'):
        p = os.path.join(rd, f)
        print(f'   {f}: exists={os.path.exists(p)} sha256={sha256(p)[:16] if os.path.exists(p) else "-"}')
    pf = os.path.join(rd, 'prop.default')
    keys = ('ro.board.platform', 'ro.board.first_api_level', 'ro.vndk.version', 'ro.sf.lcd_density',
            'ro.hardware', 'ro.boot.dynamic_partitions', 'ro.frp.pst', 'ro.product.ab_ota_partitions',
            'ro.build.version.release', 'ro.build.version.sdk', 'ro.build.version.security_patch',
            'ro.surface_flinger.primary_display_orientation', 'ro.zygote', 'ro.debuggable')
    print('   prop.default:')
    for line in open(pf, errors='replace'):
        s = line.strip()
        if s.split('=')[0] in keys:
            print('     ', s)

if __name__ == '__main__':
    main()
