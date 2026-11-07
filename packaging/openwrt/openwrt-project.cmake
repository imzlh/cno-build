# Included at the start of the nested `project(cjs)` call through
# CMAKE_PROJECT_cjs_INCLUDE.  OpenWrt's cmake.mk remains the authoritative
# toolchain file; this hook only tightens dependency and runtime-link policy.

if(NOT CMAKE_CROSSCOMPILING)
    message(FATAL_ERROR "The OpenWrt cno package must be cross-compiled by an SDK")
endif()

# CMake merely warns when an unknown -D variable is never consumed.  Require
# the sibling cno-cli ABI assertion patch to have run before this nested cjs
# project, otherwise ENDIAN/FLOAT_ABI labels could diverge from the compiler.
if(NOT COMMAND _cno_assert_target_abi OR NOT CNO_TARGET_ABI_ASSERTIONS_OK)
    message(FATAL_ERROR
        "cno-cli target ABI assertions are missing; apply "
        "cno-cli-openwrt-cross-abi.patch before packaging")
endif()
if(NOT CNO_TARGET_ENDIAN OR NOT CNO_TARGET_FLOAT_ABI)
    message(FATAL_ERROR
        "OpenWrt packaging requires explicit CNO_TARGET_ENDIAN and "
        "CNO_TARGET_FLOAT_ABI assertions")
endif()

# Do not let a developer's host package registry or environment leak into a
# target build.  OpenWrt's toolchain file supplies the target staging roots.
set(CMAKE_FIND_USE_PACKAGE_REGISTRY FALSE)
set(CMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY FALSE)
set(CMAKE_FIND_PACKAGE_NO_PACKAGE_REGISTRY TRUE)
set(CMAKE_FIND_PACKAGE_NO_SYSTEM_PACKAGE_REGISTRY TRUE)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# OpenWrt owns the shared libraries and loader.  cno must neither select a
# static dependency opportunistically nor retain a build-tree RPATH.
set(CMAKE_FIND_LIBRARY_SUFFIXES ".so")
set(OPENSSL_USE_STATIC_LIBS FALSE)
set(CURL_USE_STATIC_LIBS FALSE)
set(CURL_NO_CURL_CMAKE TRUE)
set(CMAKE_SKIP_RPATH TRUE)
set(CMAKE_SKIP_BUILD_RPATH TRUE)
set(CMAKE_BUILD_RPATH "")
set(CMAKE_INSTALL_RPATH "")
set(CMAKE_INSTALL_RPATH_USE_LINK_PATH FALSE)
