set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(CMAKE_C_COMPILER aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER aarch64-linux-gnu-g++)
set(CMAKE_ASM_COMPILER aarch64-linux-gnu-gcc)

set(CMAKE_AR aarch64-linux-gnu-ar)
set(CMAKE_RANLIB aarch64-linux-gnu-ranlib)
set(CMAKE_STRIP aarch64-linux-gnu-strip)
set(CMAKE_NM aarch64-linux-gnu-nm)
set(CMAKE_OBJCOPY aarch64-linux-gnu-objcopy)
set(CMAKE_OBJDUMP aarch64-linux-gnu-objdump)
set(CMAKE_READELF aarch64-linux-gnu-readelf)

if(NOT DEFINED ENV{AARCH64_PREFIX})
  message(FATAL_ERROR "AARCH64_PREFIX must point at the private target prefix")
endif()

file(TO_CMAKE_PATH "$ENV{AARCH64_PREFIX}" AARCH64_PREFIX)

# Do not add /usr/aarch64-linux-gnu here. GCC finds its own glibc, libgcc and
# libstdc++ sysroot, while CMake package/header/library searches must only find
# dependency artifacts rebuilt under the private prefix.
set(CMAKE_FIND_ROOT_PATH "${AARCH64_PREFIX}")
set(CMAKE_PREFIX_PATH "${AARCH64_PREFIX}")

# Host programs (cmake, Python, TableGen, etc.) execute on x86_64. Libraries,
# headers and CMake packages must be AArch64 artifacts from the private prefix.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# Avoid CMake try_run attempts against AArch64 executables.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(CMAKE_INSTALL_PREFIX "${AARCH64_PREFIX}" CACHE PATH "" FORCE)
set(CMAKE_INSTALL_LIBDIR lib CACHE STRING "" FORCE)

# The delivered tree is relocatable: executables find ../lib and libraries
# find siblings without requiring installation in /usr or /usr/local.
set(CMAKE_BUILD_RPATH "${AARCH64_PREFIX}/lib")
set(CMAKE_INSTALL_RPATH "$ORIGIN;$ORIGIN/../lib")
set(CMAKE_INSTALL_RPATH_USE_LINK_PATH FALSE)
