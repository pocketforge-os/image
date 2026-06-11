# PocketForge cross-toolchain — ARM A-Profile 10.3-2021.07 (gcc 10.3.1 / glibc 2.33)
# ===================================================================================
#
# Used inside the pocketforge/cross-build container. Sysroot is glibc 2.33 to match
# TSP. PowerVR DDK headers (EGL/GLES2) are NOT here — those bind-mount in from the
# blobs repo at /work/blobs and downstream CMake scripts add them as a second
# CMAKE_FIND_ROOT_PATH entry.
#
# Usage:
#   cmake -G Ninja \
#         -DCMAKE_TOOLCHAIN_FILE=/opt/cmake/toolchain-arm-10.3-2021.07.cmake \
#         -DCMAKE_BUILD_TYPE=Release \
#         /work/src
#
# Triplet note: aarch64-none-linux-gnu (note the `-none-`, not the Linux
# convention `-linux-`). SDL3's CMake doesn't care about the triplet —
# cmake/sdlplatform.cmake only checks CMAKE_SYSTEM_NAME — but downstream
# pkg-config / find_library calls might, so don't paper over with a symlink.

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(TOOLCHAIN_PATH /opt/arm-10.3-2021.07)
set(TOOLCHAIN_TRIPLET aarch64-none-linux-gnu)

set(CMAKE_C_COMPILER   ${TOOLCHAIN_PATH}/bin/${TOOLCHAIN_TRIPLET}-gcc)
set(CMAKE_CXX_COMPILER ${TOOLCHAIN_PATH}/bin/${TOOLCHAIN_TRIPLET}-g++)
set(CMAKE_AR           ${TOOLCHAIN_PATH}/bin/${TOOLCHAIN_TRIPLET}-ar)
set(CMAKE_RANLIB       ${TOOLCHAIN_PATH}/bin/${TOOLCHAIN_TRIPLET}-ranlib)
set(CMAKE_STRIP        ${TOOLCHAIN_PATH}/bin/${TOOLCHAIN_TRIPLET}-strip)
set(CMAKE_LINKER       ${TOOLCHAIN_PATH}/bin/${TOOLCHAIN_TRIPLET}-ld)
set(CMAKE_OBJCOPY      ${TOOLCHAIN_PATH}/bin/${TOOLCHAIN_TRIPLET}-objcopy)
set(CMAKE_OBJDUMP      ${TOOLCHAIN_PATH}/bin/${TOOLCHAIN_TRIPLET}-objdump)
set(CMAKE_NM           ${TOOLCHAIN_PATH}/bin/${TOOLCHAIN_TRIPLET}-nm)

set(CMAKE_SYSROOT ${TOOLCHAIN_PATH}/${TOOLCHAIN_TRIPLET}/libc)

# CMAKE_FIND_ROOT_PATH is a list — downstream CMake scripts can append
# /work/blobs (PowerVR DDK headers + .so files) once mounted. Keeping it
# multi-element-ready here means no toolchain-file edits later.
set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})

# Find host programs (gcc, etc.) on the host PATH; find libs/headers/packages
# only inside the sysroot (and any later-appended roots like /work/blobs).
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
