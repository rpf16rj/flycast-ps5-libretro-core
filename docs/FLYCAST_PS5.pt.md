# Flycast libretro para PS5 (PPSA99169)

Core Flycast (Sega Dreamcast/NAOMI/Atomiswave) portado para o RetroArch nativo
de PS5, compilado com o ps5-payload-sdk em Windows nativo (sem WSL).

## Estado verificado

- `build/flycast-ps5/flycast_libretro.so` — ELF64 x86-64 FreeBSD, ET_DYN,
  36,6 MB, sha256 `0b0a4fbeacc8c822...` (build com JIT via ps5_exec_allocate).
- 3 PT_LOAD (RX/R/RW) alinhados em 16 KiB, sem W+X, sem PT_TLS.
- `NEEDED`: apenas os módulos permitidos do título.
- 25 exports `retro_*` (interface libretro completa).
- 396 símbolos indefinidos, **0 ausentes** da tabela `ps5_core_import` do
  `eboot.bin` instalado — inclui `ps5_exec_allocate`/`ps5_exec_release`.
- Relocações: só `R_X86_64_RELATIVE`, `64`, `GLOB_DAT`, `JUMP_SLOT` — os 4
  tipos suportados por `src/core_loader_ps5.cpp`.
- Staged: `PPSA99169/cores/flycast_libretro.so` + `flycast_libretro.info`;
  `manifest.sha256` atualizado.

**Não verificado**: nenhum teste em console foi feito. Tudo abaixo é o plano
de deploy/verificação; o core pode falhar em runtime em pontos marcados como
"risco".

## Como reproduzir o build

Requisitos: LLVM/clang em `C:\ps5llvm` (junction sem espaços),
`C:\Program Files\CMake`, ps5-payload-sdk em `ps5-payload-sdk/`, ninja do SDK
(`win/`).

1. `git clone https://github.com/sysfce2/libretro-flycast flycast` (rev usada:
   `e36e9df`), `git submodule update --init --recursive` (inclui o nested
   `core/deps/tinygettext/external/tinycmmc`).
2. `cd flycast && git apply ../ps5tools/flycast-ps5.patch`
   - Remove `--no-undefined` para PROSPERO (imports resolvidos em runtime).
   - Fixa `PAGE_SIZE=16384` (não há `getconf` no Windows host).
   - `posix_vmem.cpp`: `prepare_jit_block`/`release_jit_block` usam
     `ps5_exec_allocate`/`ps5_exec_release` (RWX via exec pools do título);
     o `code_area` estático é ignorado.
3. Toolchain: `PS5_RetroArch/tooling/flycast/ps5-toolchain.cmake` +
   stubs `ps5-stubs.c`, `ps5-libcxx-inst.cpp` (instanciações libc++ e objetos
   extraídos de `libc++.a`: `future`, `memory`, `system_error`, `thread`) +
   `ps5tools/prospero-lld.exe` (forwarder que filtra `-pie` e força
   `-z max-page-size=0x4000 -mllvm -emulated-tls`).
4. Configurar:
   ```
   cmake -G Ninja -B build/flycast-ps5 -S flycast \
     -DCMAKE_TOOLCHAIN_FILE=<abs>/PS5_RetroArch/tooling/flycast/ps5-toolchain.cmake \
     -DLIBRETRO=ON -DUSE_VULKAN=ON -DUSE_OPENGL=OFF -DUSE_HOST_GLSLANG=OFF \
     -DUSE_HOST_LIBCHDR=OFF -DUSE_HOST_LIBZIP=OFF -DUSE_OPENMP=OFF \
     -DUSE_DISCORD=OFF -DUSE_MINIUPNPC=OFF -DUSE_LIBCDIO=OFF \
     -DENABLE_LOG=OFF -DENABLE_GDB_SERVER=OFF <flags de check OFF>
   cmake --build build/flycast-ps5 --parallel
   ```
5. Verificar: `python ps5tools/check_core.py build/flycast-ps5/flycast_libretro.so`
   e o script de imports vs `eboot_strings.json`.

## Pegadinha: core_info.cache

O frontend lê `.info` de `/app0/info` (não de `cores/`), e o upstream compila
com `core_info_cache_enable` — a lista de infos é cacheada em
`info/core_info.cache`. Se o `.so` for carregado antes do `.info` existir,
o cache guarda uma entrada "sem info" e **nunca relê o `.info`** depois.
Sintoma: Core Information vazio + browser esconde os arquivos do core
(o filtro usa a união de `supported_extensions` dos infos registrados).

Correção: apagar `info/core_info.cache` **ou** criar um arquivo vazio
`info/core_info.refresh` e reiniciar o RetroArch.

## Deploy no console

Base FTP do título: `/data/homebrew/PPSA99169/` = `/app0` no console.

1. Subir `PPSA99169/cores/flycast_libretro.so` e
   `PPSA99169/cores/flycast_libretro.info` para `cores/`.
2. Subir o `manifest.sha256` atualizado (se o instalador/verificador o usar).
3. BIOS Dreamcast (não testado HLE): `system/dc/dc_boot.bin`,
   `system/dc/dc_flash.bin` (nomes esperados pelo core; opcional `naomi.zip`/
   arquivos de BIOS arcade em `system/dc/`).
4. Conteúdo em `content/`: `.gdi`, `.cdi`, `.chd`, `.cue` (dat/lst/elf também
   suportados).

## Checklist de teste no console

1. Menu XMB lista "Sega - Dreamcast/NAOMI (Flycast)" (prova: core scan + .info).
2. Load Core → Flycast: o `ps5_core_dlopen` mapeia e roda os initializers sem
   erro de import/relocation (prova: frontend não volta pro menu/log sem crash).
3. Load Content → imagem DC: `retro_load_game` retorna, video/audio/input ok.
4. Dynarec: performance consistente com JIT (jogável, não slideshow do
   interpreter). Se travar no primeiro jogo 3D, suspeitar do path exec.
5. Savestate/loadstate e memory cards (`system/dc/` gravável).

## Riscos de runtime conhecidos (ordem de probabilidade)

- **Exec memory**: `ps5_exec_allocate` retorna RWX (dolphin escreve código JIT
  nele diretamente — assume-se o mesmo). Se fosse RW→RX separado, o SH4 rec
  falharia. O retorno pode ser NULL/-1 → `prepare_jit_block` retorna false →
  `verify()` provável `die()`. SH4 pede 11 MiB (path de alocação grande).
- **Fastmem/vmem**: `virtmem::init` usa `shm_open`/`mmap PROT_NONE` de ~600 MB
  + `MAP_FIXED` + `mprotect` + handler SIGSEGV (FPCB demand-page + rewrite de
  acesso). Se a reserva falhar, `ram_base` fica NULL → fallback malloc/JIT
  lento (degradação limpa, não crash). Se `shm_open` falhar, fallback para
  arquivo em `get_writable_data_path`.
- **SIGSEGV handler**: flycast instala via `sigaction` em `retro_init`
  (libretro.cpp:412); `context.cpp` já tem path `__FreeBSD__`/x64 (`mc_rip`).
  Necessário tanto para fastmem quanto para proteção de código/textura.
- **C++ runtime**: dtors via registro `__cxa_atexit`/`__cxa_finalize` local;
  libc++ parcial linkado (future/memory/system_error/thread + instanciações).
- **Vulkan**: usa `retro_hw_render_interface_vulkan` (device do frontend,
  mesmo modelo do beetle_psx_hw/dolphin já funcionais).

## Limitações assumidas

- Sem `--no-undefined`: imports são resolvidos pelo loader do título.
- Símbolos Annex K, PTY (`grantpt`/`unlockpt`/`ptsname`), `newlocale`/
  `uselocale`, `__register_frame` cobertos por stubs em `ps5-stubs.c`.
- `ZSTD_TRACE=0` para cortar `ZSTD_trace_*` (mesmo truque do PPSSPP).
