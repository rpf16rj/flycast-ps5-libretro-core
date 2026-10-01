#!/usr/bin/env python3
# Windows port of PS5_RetroArch/tools/check-core.py (no binutils needed).
# Mirrors its checks: ELF64 LE FreeBSD ET_DYN, NEEDED whitelist, required
# libretro exports, 16 KiB load segments. Usage: check_core.py <core.so> [--report out.json]
import sys, struct, hashlib, json
sys.path.insert(0, __file__.rsplit('\\', 1)[0].rsplit('/', 1)[0])
from readelf import parse

REQUIRED = {
    'retro_api_version', 'retro_init', 'retro_deinit', 'retro_run',
    'retro_get_system_info', 'retro_get_system_av_info', 'retro_load_game',
    'retro_load_game_special', 'retro_unload_game', 'retro_reset',
    'retro_set_environment', 'retro_set_video_refresh', 'retro_set_audio_sample',
    'retro_set_audio_sample_batch', 'retro_set_input_poll', 'retro_set_input_state',
    'retro_set_controller_port_device', 'retro_serialize_size', 'retro_serialize',
    'retro_unserialize', 'retro_get_region', 'retro_get_memory_data',
    'retro_get_memory_size', 'retro_cheat_reset', 'retro_cheat_set',
}
ALLOWED_IMPORTS = {'libkernel_web.sprx', 'libSceLibcInternal.sprx',
                   'libScePosixForWebKit.sprx'}

def inspect(path):
    data = open(path, 'rb').read()
    if len(data) < 64 or data[:8] != b'\x7fELF\x02\x01\x01\x09':
        raise ValueError('expected ELF64 little-endian FreeBSD/PS5 ABI, not a host library')
    kind, machine = struct.unpack_from('<HH', data, 16)
    if kind != 3 or machine != 62:
        raise ValueError('expected x86-64 ET_DYN shared object')
    r = parse(path)
    needed = r['needed']
    if 'libkernel_web.sprx' not in needed or set(needed) - ALLOWED_IMPORTS:
        raise ValueError(f'unexpected PS5 core imports: {needed}')
    exported, undefined = set(), set()
    for num, val, sz, typ, bnd, vis, ndx, name in r['syms']:
        if ndx == 'UND':
            undefined.add(name)
        elif typ == 'FUNC' and bnd == 'GLOBAL' and vis == 'DEFAULT':
            exported.add(name)
    missing = REQUIRED - exported
    if missing:
        raise ValueError(f'missing dynamic libretro exports: {sorted(missing)}')
    phoff = struct.unpack_from('<Q', data, 32)[0]
    phsize, phcount = struct.unpack_from('<HH', data, 54)
    if phsize != 56 or phoff + phsize * phcount > len(data):
        raise ValueError('invalid program header table')
    loads = []
    for i in range(phcount):
        ptype, flags, offset, address, _, filesz, memsz, align = struct.unpack_from(
            '<IIQQQQQQ', data, phoff + i * phsize)
        if ptype != 1:
            continue
        if (align < 0x4000 or flags & 3 == 3 or offset % 0x4000 != address % 0x4000
                or filesz > memsz or offset + filesz > len(data)):
            raise ValueError('invalid PS5 16 KiB load segment')
        loads.append({'flags': flags, 'alignment': align})
    if not loads:
        raise ValueError('no loadable segments')
    return {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data),
            'elf': 'ELF64 x86-64 ET_DYN FreeBSD/PS5', 'needed': needed,
            'libretro_exports': sorted(REQUIRED & exported),
            'undefined_symbols': sorted(undefined),
            'load_segments': loads, 'abi_passed': True,
            'console_loading_verified': False}

def main():
    path = sys.argv[1]
    report_path = None
    if '--report' in sys.argv:
        report_path = sys.argv[sys.argv.index('--report') + 1]
    try:
        report = inspect(path)
    except (OSError, ValueError) as e:
        print(f'core ABI check failed: {e}')
        sys.exit(1)
    if report_path:
        open(report_path, 'w').write(json.dumps(report, indent=2) + '\n')
    import os
    print(f"core ABI PASS: {os.path.basename(path)}; {len(REQUIRED)} exports; "
          f"{len(report['undefined_symbols'])} undefined; sha256={report['sha256'][:16]}...")

main()
