# Cross-compile Flycast with the payload SDK on a Windows host.
#
# Same contract as tooling/ppsspp/ps5-toolchain.cmake, but the SDK's Unix
# wrapper scripts cannot run here: the compilers are stock LLVM clang with the
# prospero .cmd wrapper's arguments inlined, and the linker is resolved through
# -B to a prospero-lld forwarder (PS5_TOOLS) that rewrites the PS5 driver's
# Sony-lld arguments into stock ld.lld flags.
set(CMAKE_SYSTEM_NAME FreeBSD)
set(CMAKE_SYSTEM_VERSION 9)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_CROSSCOMPILING 1)
set(PS5 TRUE)
set(PROSPERO TRUE)

# Probe binaries cannot run on the host, but they must LINK: with
# STATIC_LIBRARY here, every check_function_exists archives without resolving
# and reports false positives (libzip then calls memcpy_s/strncpy_s, which the
# payload libc does not provide). Real exe links keep detection honest.

set(PS5_PAYLOAD_SDK "$ENV{PS5_PAYLOAD_SDK}" CACHE PATH "")
set(PS5_TOOLS "$ENV{PS5_TOOLS}" CACHE PATH "")
set(PS5_LLVM "$ENV{PS5_LLVM}" CACHE PATH "")

set(CMAKE_C_COMPILER "${PS5_LLVM}/bin/clang.exe")
set(CMAKE_CXX_COMPILER "${PS5_LLVM}/bin/clang++.exe")
set(CMAKE_AR "${PS5_LLVM}/bin/llvm-ar.exe" CACHE FILEPATH "")
set(CMAKE_RANLIB "${PS5_LLVM}/bin/llvm-ranlib.exe" CACHE FILEPATH "")
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(CMAKE_FIND_ROOT_PATH "${PS5_PAYLOAD_SDK}/target")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# Mirrors win/prospero-clang.cmd: target triple, sysroot, bundled headers,
# no stack protector/PLT, emulated TLS. -B makes the PS5 driver pick up the
# prospero-lld forwarder from PS5_TOOLS instead of the SDK's broken wrapper.
set(_ps5_target
    "--target=x86_64-sie-ps5 -isysroot ${PS5_PAYLOAD_SDK} -isystem ${PS5_PAYLOAD_SDK}/target/include -fno-stack-protector -fno-plt -femulated-tls -B${PS5_TOOLS}/")
# -DZSTD_TRACE=0 mirrors tools/build-retroarch.sh: zstd emits weak tracing
# hooks whenever it sees GNUC+ELF+x86-64; the title's import table does not
# resolve them, and a WEAK-UND call target relocates to address 0.
set(CMAKE_C_FLAGS_INIT "${_ps5_target} -O2 -w -DZSTD_TRACE=0")
set(CMAKE_CXX_FLAGS_INIT "--target=x86_64-sie-ps5 -isysroot ${PS5_PAYLOAD_SDK} -isystem ${PS5_PAYLOAD_SDK}/target/include/c++/v1 -isystem ${PS5_PAYLOAD_SDK}/target/include -fno-stack-protector -fno-plt -femulated-tls -B${PS5_TOOLS}/ -frtti -fexceptions -O2 -w")
set(CMAKE_ASM_FLAGS_INIT "${_ps5_target} -w")

# Link-only probes must resolve; -nodefaultlibs keeps the wrapper defaults out.
set(CMAKE_EXE_LINKER_FLAGS_INIT
    "-nostdlib -nostartfiles -nodefaultlibs -L${PS5_PAYLOAD_SDK}/target/lib -Wl,-e,0 -lkernel_web -lSceLibcInternal -lScePosixForWebKit")

# The core's link contract: no CRT/libc, undefined symbols allowed (resolved by
# the title's generated binding table), 16 KiB pages via the shared linker
# script. PS5_CORE_LINK_INPUTS carries the local __cxa_atexit registry.
# PS5_CORE_LINK_INPUTS carries the local __cxa_atexit registry, the stub object,
# and the handful of libc++ archive members (future/memory/system_error/thread)
# for std:: symbols absent from the title's import table. The full libc++.a is
# NOT linked: its locale/io members reference a FreeBSD-14 surface (catgets,
# *_l locale functions, *at syscalls) that the table does not provide.
set(CMAKE_SHARED_LINKER_FLAGS_INIT
    "-nostdlib -nodefaultlibs -L${PS5_PAYLOAD_SDK}/target/lib -Wl,-z,undefs -Wl,--build-id=sha1 -Wl,-T,${CMAKE_CURRENT_LIST_DIR}/ps5-core.ld ${PS5_CORE_LINK_INPUTS} -lkernel_web -lSceLibcInternal -lScePosixForWebKit")
