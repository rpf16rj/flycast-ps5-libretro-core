#!/usr/bin/env python3
# Minimal readelf shim for tools/check-core.py on Windows (no binutils).
# Emulates the exact output formats the checker parses:
#   readelf -dW  -> " 0x... (NEEDED)  Shared library: [name]"
#   readelf --dyn-syms -W -> " N: addr size TYPE VIS BIND NDX name"
import sys, struct
sys.stdout.reconfigure(encoding='utf8', errors='replace')

def parse(path):
    d = open(path, 'rb').read()
    assert d[:4] == b'\x7fELF' and d[4] == 2
    phoff = struct.unpack_from('<Q', d, 32)[0]
    phentsize, phnum = struct.unpack_from('<HH', d, 54)
    segs = []
    dyn = None
    for i in range(phnum):
        p_type, p_flags, p_off, p_va, p_pa, p_fsz, p_msz, p_al = \
            struct.unpack_from('<IIQQQQQQ', d, phoff + i * phentsize)
        if p_type == 2:
            dyn = (p_off, p_fsz)
        segs.append((p_type, p_off, p_va, p_fsz, p_msz))
    def va2off(v):
        for t, o, a, fs, ms in segs:
            if t == 1 and a <= v < a + fs:
                return o + v - a
        return None
    out = {'needed': [], 'syms': [], 'soname': None}
    if dyn:
        dynstr = dynstrsz = dynsym = dynsymsz = strtab_off = 0
        ent = {}
        for i in range(dyn[1] // 16):
            tag, val = struct.unpack_from('<qQ', d, dyn[0] + i * 16)
            ent[tag] = val
            if tag == 1:
                out['needed'].append(val)
            elif tag == 14:
                out['soname'] = val
        strtab = va2off(ent.get(5, 0))
        strsz = ent.get(10, 0)
        symtab = va2off(ent.get(6, 0))
        def strx(o):
            e = d.index(b'\x00', strtab + o)
            return d[strtab + o:e].decode('utf8', 'replace')
        out['needed'] = [strx(v) for v in out['needed']]
        if out['soname'] is not None:
            out['soname'] = strx(out['soname'])
        if symtab and strtab:
            nsyms = 0
            hashtab = va2off(ent.get(4, 0))   # DT_HASH -> [nbucket, nchain, ...]
            if hashtab:
                nsyms = struct.unpack_from('<I', d, hashtab + 4)[0]
            if not nsyms:
                gnuhash = va2off(ent.get(0x6ffffef5, 0))  # DT_GNU_HASH
                if gnuhash:
                    nbuckets, symoffset, bloom_size, bloom_shift = \
                        struct.unpack_from('<IIII', d, gnuhash)
                    buckets = struct.unpack_from('<%dI' % nbuckets, d,
                                                 gnuhash + 16 + bloom_size * 8)
                    nsyms = max(buckets) if max(buckets) else 0
                    if nsyms:
                        # walk the last bucket's chain to its end
                        chains = gnuhash + 16 + bloom_size * 8 + nbuckets * 4
                        i = nsyms - symoffset
                        while not (struct.unpack_from('<I', d, chains + i * 4)[0] & 1):
                            i += 1
                        nsyms = symoffset + i + 1
            if not nsyms:
                nsyms = (strtab - symtab) // 24 if strtab > symtab else 100000
            i = 0
            while i < nsyms:
                off = symtab + i * 24
                if off + 24 > len(d) or (strtab and symtab >= strtab):
                    break
                st_name, st_info, st_other, st_shndx, st_val, st_sz = \
                    struct.unpack_from('<IBBHQQ', d, off)
                types = {0:'NOTYPE',1:'OBJECT',2:'FUNC',3:'SECTION',4:'FILE',5:'COMMON',6:'TLS',10:'GNU_IFUNC'}
                binds = {0:'LOCAL',1:'GLOBAL',2:'WEAK',10:'GNU_UNIQUE'}
                ndx = {0:'UND',0xfff1:'ABS',0xfff2:'COM'}.get(st_shndx, str(st_shndx))
                name = strx(st_name) if st_name else ''
                out['syms'].append((i, st_val, st_sz,
                    types.get(st_info & 0xf, str(st_info & 0xf)),
                    binds.get(st_info >> 4, str(st_info >> 4)),
                    'DEFAULT' if st_other == 0 else 'HIDDEN', ndx, name))
                i += 1
                if st_shndx == 0 and st_name == 0 and i > 1 and name == '':
                    pass
    return out

def main():
    args = sys.argv[1:]
    path = args[-1]
    r = parse(path)
    if '-dW' in args or '-d' in args or '--dynamic' in args:
        print('Dynamic section at offset 0x0 contains %d entries:' % len(r['needed']))
        for n in r['needed']:
            print(' 0x0000000000000001 (NEEDED)             Shared library: [%s]' % n)
        if r['soname']:
            print(' 0x000000000000000e (SONAME)             Library soname: [%s]' % r['soname'])
    if '--dyn-syms' in args or '-s' in args:
        print('Symbol table .dynsym contains %d entries:' % len(r['syms']))
        for num, val, sz, typ, bnd, vis, ndx, name in r['syms']:
            print('%5d: %016x %5d %-8s%-7s%-8s %4s %s' % (num, val, sz, typ, 'GLOBAL' if bnd=='GLOBAL' else bnd, vis, ndx, name))

if __name__ == '__main__':
    main()
