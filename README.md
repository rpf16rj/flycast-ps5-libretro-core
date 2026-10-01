# flycast_libretro para PS5 (PPSA99169)

Porte do core [Flycast](https://github.com/flyinghead/flycast) (Sega
Dreamcast / NAOMI / Atomiswave) para o RetroArch nativo de PlayStation 5
([PS5_RetroArch](https://github.com/mihawk-99/PS5_RetroArch)), compilado em
Windows nativo com o
[ps5-payload-sdk](https://github.com/ps5-payload-dev/sdk) — sem WSL, sem MSYS2.

Documentação completa (build, deploy, riscos): [docs/FLYCAST_PS5.pt.md](docs/FLYCAST_PS5.pt.md)

## O que este repositório contém

```
build.sh              Script de build reproduzível (Git Bash)
toolchain/
  ps5-toolchain.cmake Toolchain CMake: clang x86_64-sie-ps5 + SDK, sem CRT,
                      linker script ps5-core.ld, TLS emulado
  ps5-core.ld         Linker script: segmentos RX/R/RW em páginas de 16 KiB
  ps5-stubs.c         Stubs de símbolos que a tabela de imports não provê
                      (PTY, __register_frame, newlocale/uselocale)
  ps5-libcxx-inst.cpp Instanciação explícita de std::stringbuf::str(str)
  core_cxx_runtime.cpp Registro __cxa_atexit/__cxa_finalize por-DSO
patches/
  flycast-ps5.patch   Sem --no-undefined, PAGE_SIZE=16384 fixo, e
                      JIT via ps5_exec_allocate/ps5_exec_release em
                      core/linux/posix_vmem.cpp
info/
  flycast_libretro.info  Core info (display_name, extensões, database)
tools/
  prospero-lld.c      Forwarder do linker: o driver PS5 do clang chama
                      "prospero-lld" com args de lld Sony; este reescreve para
                      ld.lld stock (-z max-page-size=0x4000, emulated-tls,
                      sem -pie em --shared)
  check_core.py       Gate de ABI: ELF64 FreeBSD ET_DYN, NEEDED whitelist,
                      exports retro_*, segmentos 16 KiB (sem binutils)
  check_imports.py    Cobertura de imports vs eboot.bin / tabela do título
  readelf.py          Shim readelf -dW/--dyn-syms puro em Python
  readelf.cmd         Wrapper para o shim
```

## Requisitos

- Windows com LLVM/clang instalado em path **sem espaços** (ex.: `C:\ps5llvm`)
- CMake + o `ninja.exe` bundled do SDK (`ps5-payload-sdk/win/`)
- Checkout do [ps5-payload-sdk](https://github.com/ps5-payload-dev/sdk)
- Checkout do flycast (`sysfce2/libretro-flycast`, rev `e36e9df`) com
  submodules recursivos — inclui o nested `tinycmmc` do tinygettext
- O `eboot.bin` do título instalado (para o check de imports)

## Build

```bash
PS5_LLVM=C:/ps5llvm \
PS5_PAYLOAD_SDK=/caminho/ps5-payload-sdk \
FLYCAST_SRC=/caminho/flycast \
EBOOT=/caminho/PPSA99169/eboot.bin \
./build.sh
```

Produz `build/flycast-ps5/flycast_libretro.so` já verificado por ABI:
ELF64 x86-64 FreeBSD ET_DYN, segmentos 16 KiB RX/R/RW, só os 4 tipos de
reloc suportados pelo loader (`RELATIVE`, `64`, `GLOB_DAT`, `JUMP_SLOT`),
25 exports `retro_*`, 0 imports fora da tabela `ps5_core_import`.

## Deploy (console)

Espelhar dentro do diretório do título (`/app0`; no seu setup pode ser
`/data/homebrew/PPSA99169` ou `/usb0/homebrew/PPSA99169`):

```
cores/flycast_libretro.so
info/flycast_libretro.info
cores/flycast_libretro.info   (fallback p/ configs com info_path vazio)
```

Depois **apague `info/core_info.cache`** (ou crie um arquivo vazio
`info/core_info.refresh`) e reinicie o RetroArch — o cache de core-info do
upstream guarda entradas "sem info" de cores que foram carregados antes do
`.info` existir, e nunca as relê.

BIOS Dreamcast (opcional — HLE funciona): `system/dc/dc_boot.bin`,
`system/dc/dc_flash.bin`. ROMs `.cdi`/`.gdi`/`.chd` em qualquer pasta que o
browser alcance (`/app0`, `/data`, `/mnt/usb0`, `/mnt/usb1`).

## Estado

- [x] Build nativo Windows→PS5 completo (clang + ld.lld + payload SDK)
- [x] ABI/import/relocation gates passando
- [x] JIT/dynarec usando `ps5_exec_allocate` (pools executáveis do título)
- [x] Core carrega e boota BIOS no console
- [ ] Teste de conteúdo (gdi/cdi/chd), vídeo Vulkan, áudio, input, savestates
- [ ] Fastmem (reserva `mmap PROT_NONE` + `shm_open`) — falha degrada
      para malloc + JIT lento, não crash

## Créditos e licença

Flycast © flyinghead — GPLv2. PS5_RetroArch © mihawk-99 — GPLv3.
ps5-payload-sdk © ps5-payload-dev. Toolchain, patches e ferramentas deste
repo seguem GPLv3.
