# Flycast libretro for PS5 (PPSA99169)

The Flycast core (Sega Dreamcast/NAOMI/Atomiswave) ported to the native PS5
RetroArch, built with the ps5-payload-sdk on native Windows (no WSL).

## Verified state

- `build/flycast-ps5/flycast_libretro.so` — ELF64 x86-64 FreeBSD, ET_DYN,
  ~36 MB (build with JIT through `ps5_exec_allocate`).
- 3 PT_LOAD segments (RX/R/RW) aligned to 16 KiB, no W+X, no PT_TLS.
- `NEEDED`: only the title's whitelisted modules.
- 25 `retro_*` exports (the complete libretro interface).
- 396 undefined symbols, **0 missing** from the `ps5_core_import` table of
  the installed `eboot.bin` — including `ps5_exec_allocate`/`ps5_exec_release`.
- Relocations: only `R_X86_64_RELATIVE`, `64`, `GLOB_DAT`, `JUMP_SLOT` — the
  four types `src/core_loader_ps5.cpp` supports.
- The core loads on the console and boots the Dreamcast BIOS.

**Not yet verified**: content loading (`.gdi`/`.cdi`/`.chd`), Vulkan video,
audio, input, save states. The runtime points flagged as "risk" below can
still fail on real hardware.

## How to reproduce the build

Requirements: LLVM/clang at `C:\ps5llvm` (a junction without spaces),
CMake, the ps5-payload-sdk extracted, the SDK's bundled `ninja.exe`
(`win/`).

1. `git clone https://github.com/sysfce2/libretro-flycast flycast` (pinned
   revision: `e36e9df`), `git submodule update --init --recursive`
   (includes tinygettext's nested `core/deps/tinygettext/external/tinycmmc`).
2. Apply `patches/flycast-ps5.patch`:
   - Drops `--no-undefined` under `PROSPERO` (imports resolve at runtime
     through the title's generated binding table).
   - Fixes `PAGE_SIZE=16384` (no `getconf` on a Windows host; 16 KiB is the
     only granularity the native core loader maps).
   - `posix_vmem.cpp`: `prepare_jit_block`/`release_jit_block` use
     `ps5_exec_allocate`/`ps5_exec_release` (RWX memory from the title's
     exec pools); the static `code_area` is ignored.
3. Toolchain: `toolchain/ps5-toolchain.cmake` + the `ps5-stubs.c` and
   `ps5-libcxx-inst.cpp` objects (libc++ instantiations and members
   extracted from `libc++.a`: `future`, `memory`, `system_error`, `thread`)
   + `tools/prospero-lld.exe` (forwarder that drops `-pie` and forces
   `-z max-page-size=0x4000 -mllvm -emulated-tls`).
4. Configure and build — `build.sh` does all of this:
   ```
   PS5_LLVM=C:/ps5llvm PS5_PAYLOAD_SDK=<sdk> FLYCAST_SRC=<flycast> \
     EBOOT=<PPSA99169/eboot.bin> ./build.sh
   ```
5. Verify: `python tools/check_core.py build/flycast-ps5/flycast_libretro.so`
   and `python tools/check_imports.py <that .so> <eboot.bin>`.

## Gotcha: core_info.cache

The frontend reads `.info` files from `/app0/info` (not `cores/`), and
upstream is built with `core_info_cache_enable` — the info list is cached
in `info/core_info.cache`. If the `.so` is loaded before the `.info` exists,
the cache keeps a "no info" entry and **never re-reads the `.info`**
afterwards. Symptom: empty Core Information + the browser hides the core's
files (the filter uses the union of `supported_extensions` from registered
infos).

Fix: delete `info/core_info.cache` **or** create an empty
`info/core_info.refresh` file and restart RetroArch.

## Baked-in defaults

The patch makes the core's RetroArch defaults match a 4K PS5 output, so no
core-options file is required for a good out-of-the-box picture:

- `flycast_internal_resolution` → `2880x2160` (x4.5). Fallback
  `config::RenderResolution` is `2160` as well, so the core renders at 4.5x
  even if the frontend never answers `GET_VARIABLE`.
- `flycast_anisotropic_filtering` → `16` (labeled "Anisotropic Filtering";
  Flycast has no MSAA option — AF16 is the maximum texture filtering).
- `flycast_alpha_sorting` → `per-pixel (accurate)` — the "blending" path:
  Vulkan OIT transparency (modifier volumes stay `enabled` as upstream).
  `config::RenderType` defaults to `Vulkan_OIT` for the same fallback
  coverage.
- `flycast_widescreen_hack` → `enabled` — draws geometry outside 4:3,
  matching the title's fullscreen 16:9 output. `flycast_widescreen_cheats`
  stays `disabled` (per-game cheat codes, not the geometry hack).

`flycast_anisotropic_filtering` is also switched from `Option<int>` to
`IntOption`: `Option<int>::doLoad` returns the *index* of the selected
string (`"16"` → `4`), silently capping real anisotropy at 4x; `IntOption`
parses the value. This is an upstream bug that only shows on the PS5
because the default moved past index 3.

`.opt` overrides still work on top of these defaults when the frontend
persists them.

## Core-option overrides

RetroArch writes per-game/per-core option files under
`/app0/config/Flycast/<game>.opt` when the core unloads or the menu's
"Overrides" entry is used — the file is only created if a setting differs
from the definitions' defaults or the override is saved explicitly. If
"Save Core Override" produces no file, check `log_dir` (`/app0/*.log`)
for `core_options`/`config_file_write` errors and confirm `config/` is
writable from the homebrew's mount. With the baked defaults above, the
core already starts at the desired picture settings, so overrides are
only needed for per-game tweaks.

## Deploy on the console

Title FTP base: `/data/homebrew/PPSA99169/` = `/app0` on the console (or
`/usb0/homebrew/PPSA99169/` when running from USB).

1. Copy `flycast_libretro.so` to `cores/` and `flycast_libretro.info` to
   `info/` (a duplicate in `cores/` covers configs with an empty info path).
2. Dreamcast BIOS (HLE untested): `system/dc/dc_boot.bin`,
   `system/dc/dc_flash.bin` (names the core expects; optional `naomi.zip`/
   arcade BIOS files under `system/dc/`).
3. Content anywhere the browser reaches: `.gdi`, `.cdi`, `.chd`, `.cue`
   (dat/lst/elf also supported).

## Console test checklist

1. The XMB menu lists "Sega - Dreamcast/Naomi (Flycast)" (proves: core scan
   + .info).
2. Load Core → Flycast: the `ps5_core_dlopen` maps it and runs the
   initializers with no import/relocation error (proves: no crash back to
   the menu).
3. Load Content → a DC image: `retro_load_game` returns, video/audio/input
   work.
4. Dynarec: performance consistent with JIT (playable, not interpreter
   slideshow). If it hangs on the first 3D game, suspect the exec path.
5. Save state/load state and memory cards (`system/dc/` writable).

## Known runtime risks (in order of likelihood)

- **Exec memory**: `ps5_exec_allocate` returns RWX (Dolphin writes JIT code
  into it directly — assumed the same here). If it were a separate RW→RX
  view the SH4 rec would fail. NULL/-1 return → `prepare_jit_block` returns
  false → `verify()` probably `die()`s. The SH4 asks for 11 MiB (the large
  allocation path).
- **Fastmem/vmem**: `virtmem::init` uses `shm_open`/`mmap PROT_NONE` of
  ~600 MB + `MAP_FIXED` + `mprotect` + a SIGSEGV handler (FPCB demand-page +
  access rewrite). If the reservation fails, `ram_base` stays NULL → malloc
  + slow JIT fallback (clean degradation, not a crash). If `shm_open` fails,
  it falls back to a file under `get_writable_data_path`.
- **SIGSEGV handler**: flycast installs it via `sigaction` in `retro_init`;
  `context.cpp` already has a `__FreeBSD__`/x64 path (`mc_rip`). Needed both
  for fastmem and for code/texture protection.
- **C++ runtime**: destructors through the local `__cxa_atexit`/
  `__cxa_finalize` registry; partial libc++ linked in
  (future/memory/system_error/thread + instantiations).
- **Vulkan**: uses `retro_hw_render_interface_vulkan` (the frontend's
  device, the same model the already-working beetle_psx_hw/dolphin use).

## Assumed limitations

- No `--no-undefined`: imports are resolved by the title's loader.
- Annex K symbols, PTY (`grantpt`/`unlockpt`/`ptsname`), `newlocale`/
  `uselocale`, `__register_frame` are covered by stubs in `ps5-stubs.c`.
- `ZSTD_TRACE=0` cuts the `ZSTD_trace_*` hooks (same trick PPSSPP uses).
