#!/usr/bin/env bash
# Build flycast_libretro.so for the PS5 RetroArch title (PPSA99169) on a
# native Windows host (Git Bash). No WSL needed.
#
# Layout expected:
#   repo/
#     build.sh            (this file)
#     toolchain/          ps5-toolchain.cmake, ps5-core.ld, stubs, ld script
#     tools/              prospero-lld.c, check_core.py, check_imports.py, ...
#     patches/            flycast-ps5.patch
#
# Environment variables (required):
#   PS5_LLVM        LLVM/clang prefix, e.g. C:/ps5llvm (path without spaces!)
#   PS5_PAYLOAD_SDK ps5-payload-sdk checkout
#   FLYCAST_SRC     flycast source tree (git clone of libretro-flycast)
#   EBOOT           path to the title's eboot.bin (import coverage check,
#                   optional)
#
# Example:
#   PS5_LLVM=C:/ps5llvm \
#   PS5_PAYLOAD_SDK=C:/work/ps5-payload-sdk \
#   FLYCAST_SRC=C:/work/flycast \
#   EBOOT=C:/work/PPSA99169/eboot.bin \
#   ./build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TOOLS_OUT="$ROOT/build/tools"
OBJS="$ROOT/build/objs"
OUT="$ROOT/build/flycast-ps5"

: "${PS5_LLVM:?set PS5_LLVM to the LLVM prefix (path without spaces)}"
: "${PS5_PAYLOAD_SDK:?set PS5_PAYLOAD_SDK to the ps5-payload-sdk checkout}"
: "${FLYCAST_SRC:?set FLYCAST_SRC to the flycast source tree}"

CLANG="$PS5_LLVM/bin/clang.exe"
CLANGXX="$PS5_LLVM/bin/clang++.exe"
AR="$PS5_LLVM/bin/llvm-ar.exe"
LLDLIB="$PS5_LLVM/bin/llvm-lib.exe"

# Flags mirroring win/prospero-clang.cmd (the .cmd wrappers break on spaces in
# paths, so we pass the arguments directly to stock clang).
PS5_FLAGS="--target=x86_64-sie-ps5 -isysroot $PS5_PAYLOAD_SDK -isystem $PS5_PAYLOAD_SDK/target/include -fno-stack-protector -fno-plt -femulated-tls"
# libc++ headers must precede the C library headers: <cstdlib> includes_next
# <stdlib.h> and finds the libc one first otherwise.
PS5_CXXFLAGS="-isystem $PS5_PAYLOAD_SDK/target/include/c++/v1 $PS5_FLAGS -frtti -fexceptions"
PS5_LD="-nostdlib -nostartfiles -nodefaultlibs -L$PS5_PAYLOAD_SDK/target/lib"

mkdir -p "$TOOLS_OUT" "$OBJS/libcxx" "$OUT"

# --- 1. prospero-lld forwarder (host tool, Windows exe, no libc) ----------
# clang -target x86_64-sie-ps5 hardcodes the linker name "prospero-lld" and
# emits Sony-lld arguments the stock ld.lld does not accept. The forwarder
# rewrites them; ld.lld.exe must sit next to it so CreateProcess finds it.
if [ ! -x "$TOOLS_OUT/prospero-lld.exe" ]; then
    if [ ! -f "$TOOLS_OUT/kernel32.lib" ]; then
        cat > "$TOOLS_OUT/kernel32.def" <<'EOF'
LIBRARY kernel32.dll
EXPORTS
  CreateProcessA
  WaitForSingleObject
  GetExitCodeProcess
  ExitProcess
  GetStdHandle
  WriteFile
  GetCommandLineA
EOF
        MSYS2_ARG_CONV_EXCL='/def;/out;/machine' \
        "$LLDLIB" /def:"$(cygpath -w "$TOOLS_OUT/kernel32.def")" \
            /out:"$(cygpath -w "$TOOLS_OUT/kernel32.lib")" /machine:x64
    fi
    "$CLANG" --target=x86_64-pc-windows-msvc -O2 -nostdlib -fuse-ld=lld \
        "$ROOT/tools/prospero-lld.c" "$TOOLS_OUT/kernel32.lib" \
        -Wl,/entry:mainCRTStartup -Wl,/subsystem:console -o "$TOOLS_OUT/prospero-lld.exe"
fi
cp -f "$PS5_LLVM/bin/ld.lld.exe" "$TOOLS_OUT/ld.lld.exe"
export PS5_TOOLS="$TOOLS_OUT"

# --- 2. Core-local runtime objects ----------------------------------------
# core_cxx_runtime: __cxa_atexit/__cxa_finalize registry per DSO so global
# destructors do not register with the process-wide atexit list.
# ps5-stubs: symbols flycast references on code paths that never run here
# (PTY, unwind registration, locale_t helpers) and the table cannot provide.
# ps5-libcxx-inst: explicit instantiation of std::stringbuf::str(str), which
# is inline-only in the SDK headers but absent from the import table.
"$CLANG"   $PS5_FLAGS    -O2 -c "$ROOT/toolchain/ps5-stubs.c"           -o "$OBJS/ps5-stubs.o"
"$CLANGXX" $PS5_CXXFLAGS -O2 -c "$ROOT/toolchain/core_cxx_runtime.cpp"  -o "$OBJS/core_cxx_runtime.o"
"$CLANGXX" $PS5_CXXFLAGS -O2 -c "$ROOT/toolchain/ps5-libcxx-inst.cpp"   -o "$OBJS/ps5-libcxx-inst.o"

# --- 3. Minimal libc++ members ---------------------------------------------
# Only the members flycast needs (std::future machinery). Linking the full
# libc++.a pulls in FreeBSD-14 locale/fs symbols the title does not export.
(cd "$OBJS/libcxx" && "$AR" x \
    "$PS5_PAYLOAD_SDK/target/lib/libc++.a" \
    future.cpp.o memory.cpp.o system_error.cpp.o thread.cpp.o)

# Native clang does not understand MSYS paths (/d/a/...); emit mixed Windows
# paths (D:/a/...) so the link line is valid when cmake expands it.
CORE_LINK_INPUTS=""
for o in "$OBJS/core_cxx_runtime.o" "$OBJS/ps5-stubs.o" "$OBJS/ps5-libcxx-inst.o" \
         "$OBJS/libcxx/future.cpp.o" "$OBJS/libcxx/memory.cpp.o" \
         "$OBJS/libcxx/system_error.cpp.o" "$OBJS/libcxx/thread.cpp.o"; do
    CORE_LINK_INPUTS="$CORE_LINK_INPUTS $(cygpath -m "$o")"
done
CORE_LINK_INPUTS="${CORE_LINK_INPUTS# }"

# --- 4. Patch the flycast tree ---------------------------------------------
(cd "$FLYCAST_SRC" && git apply --check "$ROOT/patches/flycast-ps5.patch" \
    2>/dev/null && git apply "$ROOT/patches/flycast-ps5.patch" \
    || echo "patches/flycast-ps5.patch already applied or does not apply cleanly; continuing")

# --- 5. Configure -----------------------------------------------------------
# The HAVE_*=FALSE entries disable libzip feature checks that succeed against
# the SDK archives but resolve to Annex K / Win32 names absent from the title
# import table. STATIC_LIBRARY probes were the false-positive source; the
# toolchain links real test binaries instead.
cmake -G Ninja -S "$FLYCAST_SRC" -B "$OUT" \
    -DCMAKE_TOOLCHAIN_FILE="$ROOT/toolchain/ps5-toolchain.cmake" \
    -DCMAKE_MAKE_PROGRAM="$PS5_PAYLOAD_SDK/win/ninja.exe" \
    "-DPS5_CORE_LINK_INPUTS=$CORE_LINK_INPUTS" \
    -DLIBRETRO=ON -DUSE_VULKAN=ON -DUSE_OPENGL=OFF \
    -DUSE_HOST_GLSLANG=OFF -DUSE_HOST_LIBCHDR=OFF -DUSE_HOST_LIBZIP=OFF \
    -DUSE_OPENMP=OFF -DUSE_DISCORD=OFF -DUSE_MINIUPNPC=OFF \
    -DUSE_LIBCDIO=OFF -DENABLE_LOG=OFF -DENABLE_GDB_SERVER=OFF \
    -DHAVE_MEMCPY_S=FALSE -DHAVE_STRNCPY_S=FALSE -DHAVE_STRERROR_S=FALSE \
    -DHAVE_STRERRORLEN_S=FALSE -DHAVE_SNPRINTF_S=FALSE -DHAVE_LOCALTIME_S=FALSE \
    -DHAVE_CLONEFILE=FALSE -DHAVE_EXPLICIT_BZERO=FALSE \
    -DHAVE_EXPLICIT_MEMSET=FALSE -DHAVE_FTS_OPEN=FALSE -DHAVE_SETMODE=FALSE \
    -DHAVE_STRICMP=FALSE -DHAVE__CLOSE=FALSE -DHAVE__DUP=FALSE \
    -DHAVE__FDOPEN=FALSE -DHAVE__FILENO=FALSE -DHAVE__SETMODE=FALSE \
    -DHAVE__SNPRINTF=FALSE -DHAVE__SNPRINTF_S=FALSE -DHAVE__SNWPRINTF_S=FALSE \
    -DHAVE__STRDUP=FALSE -DHAVE__STRICMP=FALSE -DHAVE__STRTOI64=FALSE \
    -DHAVE__STRTOUI64=FALSE -DHAVE__UNLINK=FALSE

# --- 6. Build ----------------------------------------------------------------
"$PS5_PAYLOAD_SDK/win/ninja.exe" -C "$OUT" flycast_libretro

# --- 7. Verify ---------------------------------------------------------------
python "$ROOT/tools/check_core.py" "$OUT/flycast_libretro.so" \
    --report "$OUT/abi.json"
if [ -n "${EBOOT:-}" ]; then
    python "$ROOT/tools/check_imports.py" "$OUT/flycast_libretro.so" "$EBOOT"
fi

echo
echo "Built: $OUT/flycast_libretro.so"
echo "Stage with info/flycast_libretro.info into <title>/cores/ and <title>/info/"
