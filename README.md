# flycast_libretro for PS5 (PPSA99169)

Port of the [Flycast](https://github.com/flyinghead/flycast) libretro core
(Sega Dreamcast / NAOMI / Atomiswave) to the native PlayStation 5 RetroArch —
**this port targets the
[PS5_RetroArch](https://github.com/mihawk-99/PS5_RetroArch) project by
mihawk-99** (title `PPSA99169`; the original repository may be
unavailable/404, but all the work here follows that port's ABI contract,
custom core loader and deploy layout). Built on native Windows with the
[ps5-payload-sdk](https://github.com/ps5-payload-dev/sdk) — no WSL, no MSYS2.

Full documentation (build, deploy, risks): [docs/FLYCAST_PS5.md](docs/FLYCAST_PS5.md)

## What this repository contains

```
build.sh              Reproducible build script (Git Bash)
toolchain/
  ps5-toolchain.cmake CMake toolchain: x86_64-sie-ps5 clang + SDK, no CRT,
                      the ps5-core.ld linker script, emulated TLS
  ps5-core.ld         Linker script: RX/R/RW segments on 16 KiB pages
  ps5-stubs.c         Stubs for symbols the import table does not provide
                      (PTY, __register_frame, newlocale/uselocale)
  ps5-libcxx-inst.cpp Explicit instantiation of std::stringbuf::str(str)
  core_cxx_runtime.cpp Per-DSO __cxa_atexit/__cxa_finalize registry
patches/
  flycast-ps5.patch   No --no-undefined, fixed PAGE_SIZE=16384, and
                      JIT through ps5_exec_allocate/ps5_exec_release in
                      core/linux/posix_vmem.cpp
info/
  flycast_libretro.info  Core metadata (display name, extensions, database)
tools/
  prospero-lld.c      Linker forwarder: the clang PS5 driver invokes
                      "prospero-lld" with Sony lld arguments; this rewrites
                      them for stock ld.lld (-z max-page-size=0x4000,
                      emulated-tls, no -pie under --shared)
  check_core.py       ABI gate: ELF64 FreeBSD ET_DYN, NEEDED whitelist,
                      retro_* exports, 16 KiB segments (no binutils needed)
  check_imports.py    Import coverage vs eboot.bin / the title's table
  readelf.py          Pure-Python readelf -dW/--dyn-syms shim
  readelf.cmd         Wrapper for the shim
```

## Requirements

- Windows with LLVM/clang installed at a path **without spaces**
  (e.g. `C:\ps5llvm`)
- CMake + the SDK's bundled `ninja.exe` (`ps5-payload-sdk/win/`)
- A checkout of the [ps5-payload-sdk](https://github.com/ps5-payload-dev/sdk)
- A checkout of flycast (`sysfce2/libretro-flycast`, rev `e36e9df`) with
  recursive submodules — including tinygettext's nested `tinycmmc`
- The installed title's `eboot.bin` (for the import coverage check)

## Build

```bash
PS5_LLVM=C:/ps5llvm \
PS5_PAYLOAD_SDK=/path/to/ps5-payload-sdk \
FLYCAST_SRC=/path/to/flycast \
EBOOT=/path/to/PPSA99169/eboot.bin \
./build.sh
```

Produces `build/flycast-ps5/flycast_libretro.so`, already ABI-checked:
ELF64 x86-64 FreeBSD ET_DYN, 16 KiB RX/R/RW segments, only the four
relocation types the loader supports (`RELATIVE`, `64`, `GLOB_DAT`,
`JUMP_SLOT`), 25 `retro_*` exports, 0 imports outside the `ps5_core_import`
table.

## Deploy (console)

Mirror into the title directory (`/app0`; depending on your setup that is
`/data/homebrew/PPSA99169` or `/usb0/homebrew/PPSA99169`):

```
cores/flycast_libretro.so
info/flycast_libretro.info
cores/flycast_libretro.info   (fallback for configs with an empty info path)
```

Then **delete `info/core_info.cache`** (or create an empty
`info/core_info.refresh` file) and restart RetroArch — the upstream
core-info cache keeps "no info" entries for cores that were loaded before
the `.info` existed and never reads them again.

Dreamcast BIOS (optional — HLE works): `system/dc/dc_boot.bin`,
`system/dc/dc_flash.bin`. `.cdi`/`.gdi`/`.chd` ROMs in any folder the
browser can reach (`/app0`, `/data`, `/mnt/usb0`, `/mnt/usb1`).

## Status

- [x] Complete native Windows→PS5 build (clang + ld.lld + payload SDK)
- [x] ABI/import/relocation gates passing
- [x] JIT/dynarec on `ps5_exec_allocate` (the title's executable pools)
- [x] Core loads and boots the BIOS on the console
- [ ] Content test (gdi/cdi/chd), Vulkan video, audio, input, save states
- [ ] Fastmem (`mmap PROT_NONE` reservation + `shm_open`) — failure degrades
      to malloc + slow JIT, not a crash

## Credits and licence

Flycast © flyinghead — GPLv2. PS5_RetroArch © mihawk-99 — GPLv3.
ps5-payload-sdk © ps5-payload-dev. The toolchain, patches and tools in this
repository are GPLv3.
