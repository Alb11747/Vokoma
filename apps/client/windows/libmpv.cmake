# Replaces the libmpv that media_kit bundles with a pinned official mpv build.
#
# media_kit_libs_windows_video 1.0.11 ships libmpv from an mpv git snapshot of
# 2023-09-24 (between 0.36 and 0.37). This downloads libmpv from the mpv
# project's own release (a single self-contained libmpv-2.dll with the same
# client API) and installs it over media_kit's copy, so the app runs on the
# same mpv version as the engine benchmark. Configure with
# -DVOKOMA_PINNED_LIBMPV=OFF to fall back to media_kit's library.
#
# To update: change the version and hash below (sha256 of the release zip).
option(VOKOMA_PINNED_LIBMPV "Replace media_kit's libmpv with the pinned mpv release" ON)

set(VOKOMA_LIBMPV_VERSION "0.42.0")
set(VOKOMA_LIBMPV_SHA256 "8e5f77430efc53ef175804ba6618527e3af0448a0dcabf04d3cc72659d1a6fce")

if(VOKOMA_PINNED_LIBMPV)
  set(_name "libmpv-v${VOKOMA_LIBMPV_VERSION}-x86_64-w64-mingw32-lgpl")
  set(_zip "${CMAKE_BINARY_DIR}/${_name}.zip")
  set(_dir "${CMAKE_BINARY_DIR}/${_name}")
  if(NOT EXISTS "${_dir}/libmpv-2.dll")
    file(DOWNLOAD
      "https://github.com/mpv-player/mpv/releases/download/v${VOKOMA_LIBMPV_VERSION}/${_name}.zip"
      "${_zip}"
      EXPECTED_HASH SHA256=${VOKOMA_LIBMPV_SHA256}
      TLS_VERIFY ON
      SHOW_PROGRESS)
    file(ARCHIVE_EXTRACT INPUT "${_zip}" DESTINATION "${_dir}" PATTERNS "libmpv-2.dll" "LICENSE.LGPL")
    file(REMOVE "${_zip}")
  endif()
  # Installed after the plugin libraries, so it overwrites media_kit's copy.
  install(FILES "${_dir}/libmpv-2.dll" "${_dir}/LICENSE.LGPL"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()
