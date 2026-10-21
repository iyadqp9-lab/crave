#!/usr/bin/env bash
# Build the LineageOS 18.1 / Android 11 ROM for Samsung Galaxy Tab A SM-T355Y.
set -Eeo pipefail

decode_b64() {
  printf '%s' "$1" | base64 -d
}

BUILD_DIFFERENT_ROM="$(decode_b64 "${BUILD_DIFFERENT_ROM_B64:?missing build command}")"
LOCAL_MANIFEST="$(decode_b64 "${LOCAL_MANIFEST_B64:?missing local manifest}")"
REMOVALS="$(decode_b64 "${REMOVALS_B64:-}")"
LUNCH="$(decode_b64 "${LUNCH_B64:?missing lunch target}")"
BUILD_COMMAND="$(decode_b64 "${BUILD_COMMAND_B64:?missing build command}")"
DEVICE_NAME="$(decode_b64 "${DEVICE_NAME_B64:?missing device codename}")"
PRODUCT_NAME="$(decode_b64 "${PRODUCT_NAME_B64:?missing product name}")"
BUILD_USERNAME="$(decode_b64 "${ACTOR_B64:-github-actions}")"
BUILD_HOSTNAME="crave"
export BUILD_USERNAME BUILD_HOSTNAME

echo "=== IYAD AZIEZ OS build preflight ==="
echo "Workspace: $(pwd)"
echo "Device: $DEVICE_NAME"
echo "Product: $PRODUCT_NAME"
if [[ ! -d .repo ]]; then
  echo "::error::No initialized Android .repo directory in the Crave workspace."
  exit 10
fi

# Clean the old local manifest and only the extra paths the user requested.
rm -rf .repo/local_manifests
if [[ -n "$REMOVALS" ]]; then
  while IFS= read -r remove_path; do
    [[ -z "$remove_path" ]] || rm -rf -- "$remove_path"
  done < <(printf '%s\n' "$REMOVALS" | tr ' ' '\n')
fi

echo "Initializing Android manifest..."
bash -c "$BUILD_DIFFERENT_ROM"
echo "Installing the IYAD AZIEZ local manifest..."
bash -c "$LOCAL_MANIFEST"

if ! find .repo/local_manifests -maxdepth 1 -type f -name '*.xml' -print -quit 2>/dev/null | grep -q .; then
  echo "::error::No XML local manifest was downloaded into .repo/local_manifests."
  find .repo/local_manifests -maxdepth 2 -type f -print 2>/dev/null || true
  exit 11
fi
for manifest_file in .repo/local_manifests/*.xml; do
  [[ -f "$manifest_file" ]] || continue
  if ! grep -q '<manifest' "$manifest_file"; then
    echo "::error::Invalid local manifest file: $manifest_file"
    head -n 30 "$manifest_file" || true
    exit 12
  fi
done

echo "Syncing repositories..."
if [[ -x /usr/bin/resync ]]; then
  /usr/bin/resync
elif [[ -x /opt/crave/resync.sh ]]; then
  /opt/crave/resync.sh
else
  repo sync --force-sync --no-clone-bundle --no-tags -c -j2
fi

echo "Validating the target device tree..."
if [[ ! -f "device/samsung/$DEVICE_NAME/device.mk" ]]; then
  echo "::error::Device tree is missing: device/samsung/$DEVICE_NAME/device.mk"
  echo "Manifest files:"
  find .repo/local_manifests -maxdepth 2 -type f -print 2>/dev/null || true
  echo "Relevant synced projects:"
  repo list 2>/dev/null | grep -E 'device/samsung/(gt58lte|gte-common|msm8916-common)' || true
  exit 13
fi
if [[ ! -f "device/samsung/$DEVICE_NAME/AndroidProducts.mk" ]]; then
  echo "::error::AndroidProducts.mk is missing for $DEVICE_NAME."
  exit 14
fi
if ! grep -RqsF "PRODUCT_NAME := $PRODUCT_NAME" "device/samsung/$DEVICE_NAME"; then
  echo "::error::Product $PRODUCT_NAME was not found in the selected device tree."
  grep -R "PRODUCT_NAME" "device/samsung/$DEVICE_NAME" || true
  exit 15
fi

# Repair the two old proprietary GPS paths used by this device tree.
sed -i \
  -e 's#vendor/samsung/msm8916-common/proprietary/lib/libloc_api_v02.so#vendor/samsung/msm8916-common/proprietary/vendor/lib/libloc_api_v02.so#g' \
  -e 's#vendor/samsung/msm8916-common/proprietary/lib/libloc_ds_api.so#vendor/samsung/msm8916-common/proprietary/vendor/lib/libloc_ds_api.so#g' \
  "device/samsung/$DEVICE_NAME/device.mk"

# The upstream SM-T355Y device tree requests a regional kernel config fragment,
# but the selected Galaxy-MSM8916 lineage-17.1 kernel branch does not ship it.
# Keep the generic msm8916_sec_defconfig as the base and create an EMPTY fragment
# only when the exact AUS fragment is missing; do not copy another model/region's config.
if [[ "$DEVICE_NAME" == "gt58lte" && -d kernel/samsung/msm8916/arch/arm/configs ]]; then
  AUS_VARIANT_CONFIG="kernel/samsung/msm8916/arch/arm/configs/msm8916_sec_gt58lte_aus_defconfig"
  if [[ ! -f "$AUS_VARIANT_CONFIG" ]]; then
    echo "::warning::Kernel branch lacks msm8916_sec_gt58lte_aus_defconfig; creating an empty regional fragment and retaining the generic msm8916_sec_defconfig."
    : > "$AUS_VARIANT_CONFIG"
  fi
fi

# Android 11's bundled Clang 3.8 requires the legacy ncurses5/tinfo5 ABI.
# Always extract and prepend these libraries: ldconfig can report host libraries
# that are not visible to the isolated build process used by Crave.
if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "::error::The ncurses compatibility packages are amd64-only; got $(uname -m)."
  exit 16
fi
if ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "::error::dpkg-deb is unavailable; cannot unpack the legacy compatibility libraries."
  exit 17
fi
NCURSES_ROOT="$HOME/.cache/iyad-aziez/ncurses5"
NCURSES_PACKAGES="$NCURSES_ROOT/packages"
NCURSES_EXTRACT="$NCURSES_ROOT/root"
mkdir -p "$NCURSES_PACKAGES" "$NCURSES_EXTRACT"
PACKAGE_BASE="https://archive.ubuntu.com/ubuntu/pool/universe/n/ncurses"
for package in libtinfo5_6.2-0ubuntu2.1_amd64.deb libncurses5_6.2-0ubuntu2.1_amd64.deb; do
  if [[ ! -s "$NCURSES_PACKAGES/$package" ]]; then
    curl --fail --location --retry 3 --connect-timeout 20 \
      "$PACKAGE_BASE/$package" --output "$NCURSES_PACKAGES/$package"
  fi
  dpkg-deb -f "$NCURSES_PACKAGES/$package" Architecture | grep -qx 'amd64'
  dpkg-deb -x "$NCURSES_PACKAGES/$package" "$NCURSES_EXTRACT"
done
NCURSES_LIBRARY="$(find "$NCURSES_EXTRACT" -name 'libncurses.so.5' -print -quit)"
if [[ -z "$NCURSES_LIBRARY" ]]; then
  echo "::error::libncurses.so.5 was not found after extracting the compatibility packages."
  exit 18
fi
NCURSES_LIBRARY_DIR="$(dirname "$NCURSES_LIBRARY")"
if [[ ! -e "$NCURSES_LIBRARY_DIR/libtinfo.so.5" ]]; then
  echo "::error::libtinfo.so.5 was not found alongside libncurses.so.5."
  exit 19
fi
export LD_LIBRARY_PATH="$NCURSES_LIBRARY_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
echo "Using legacy compiler libraries from: $NCURSES_LIBRARY_DIR"
ls -l "$NCURSES_LIBRARY_DIR"/libncurses.so.5 "$NCURSES_LIBRARY_DIR"/libtinfo.so.5

# Some Android build/Ninja subprocesses sanitize LD_LIBRARY_PATH. Embed an ELF
# RPATH in the legacy tools so the dynamic loader can still find ncurses5.
PATCHELF_BIN="$(command -v patchelf || true)"
if [[ -z "$PATCHELF_BIN" ]]; then
  PATCHELF_ROOT="$HOME/.cache/iyad-aziez/patchelf"
  PATCHELF_DEB="$PATCHELF_ROOT/patchelf_0.14.3-1+b1_amd64.deb"
  PATCHELF_EXTRACT="$PATCHELF_ROOT/root"
  mkdir -p "$PATCHELF_ROOT" "$PATCHELF_EXTRACT"
  if [[ ! -s "$PATCHELF_DEB" ]]; then
    curl --fail --location --retry 3 --connect-timeout 20 \
      "https://deb.debian.org/debian/pool/main/p/patchelf/patchelf_0.14.3-1+b1_amd64.deb" \
      --output "$PATCHELF_DEB"
  fi
  dpkg-deb -f "$PATCHELF_DEB" Architecture | grep -qx 'amd64'
  dpkg-deb -x "$PATCHELF_DEB" "$PATCHELF_EXTRACT"
  PATCHELF_BIN="$(find "$PATCHELF_EXTRACT" -type f -name patchelf -print -quit)"
fi
if [[ -z "$PATCHELF_BIN" || ! -x "$PATCHELF_BIN" ]]; then
  echo "::error::Could not obtain patchelf to fix legacy compiler runtime paths."
  exit 24
fi

CLANG_BIN="prebuilts/clang/host/linux-x86/clang-3289846/bin"
for legacy_tool in "$CLANG_BIN/clang.real" "$CLANG_BIN/llvm-as"; do
  if [[ ! -x "$legacy_tool" ]]; then
    echo "::error::Expected Android 11 tool is missing: $legacy_tool"
    exit 20
  fi
  old_rpath="$("$PATCHELF_BIN" --print-rpath "$legacy_tool" 2>/dev/null || true)"
  new_rpath="$NCURSES_LIBRARY_DIR"
  if [[ -n "$old_rpath" ]]; then
    new_rpath="$new_rpath:$old_rpath"
  fi
  "$PATCHELF_BIN" --force-rpath --set-rpath "$new_rpath" "$legacy_tool"
  echo "Patched RPATH for $legacy_tool: $("$PATCHELF_BIN" --print-rpath "$legacy_tool")"
  if ldd "$legacy_tool" 2>&1 | grep -q 'not found'; then
    echo "::error::Unresolved shared library dependency for $legacy_tool after RPATH patch."
    ldd "$legacy_tool" || true
    exit 21
  fi
  "$legacy_tool" --version >/dev/null
done
echo "Legacy compiler dependencies are available."

source build/envsetup.sh
eval "$LUNCH"
make installclean

# Restore the shell environment too, but rely on the embedded RPATH above
# because Android build tools may sanitize LD_LIBRARY_PATH for child processes.
export LD_LIBRARY_PATH="$NCURSES_LIBRARY_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
echo "Final compiler library path: $LD_LIBRARY_PATH"
for legacy_tool in "$CLANG_BIN/clang.real" "$CLANG_BIN/llvm-as"; do
  echo "Checking legacy compiler RPATH after envsetup: $legacy_tool"
  "$PATCHELF_BIN" --print-rpath "$legacy_tool"
  ldd "$legacy_tool" | grep -E 'lib(ncurses|tinfo)\.so\.5'
  if ldd "$legacy_tool" 2>&1 | grep -q 'not found'; then
    echo "::error::Unresolved shared library dependency after envsetup for $legacy_tool"
    ldd "$legacy_tool" || true
    exit 23
  fi
  "$legacy_tool" --version >/dev/null
done
echo "Legacy compiler RPATH dependencies verified immediately before compilation."

# Soong generates host tools such as llvm-tblgen during the build, after the
# initial preflight. A one-time scan misses those newly-created executables.
# Keep a lightweight watcher running while Ninja builds, and embed the legacy
# library path as soon as a generated executable needs ncurses5/tinfo5.
SOONG_HOST_BIN="out/soong/host/linux-x86/bin"

patch_one_soong_tool() {
  local host_tool="$1"
  [[ -e "$host_tool" || -L "$host_tool" ]] || return 0

  local resolved_tool
  resolved_tool="$(readlink -f "$host_tool" 2>/dev/null || true)"
  [[ -n "$resolved_tool" && -f "$resolved_tool" && -x "$resolved_tool" ]] || return 0

  # IMPORTANT: do not inherit LD_LIBRARY_PATH during this test. The Android
  # build system sanitizes it for some Ninja subprocesses, so ordinary "ldd"
  # can falsely say the dependency is available even though llvm-tblgen fails.
  local tool_deps
  tool_deps="$(env -u LD_LIBRARY_PATH ldd "$resolved_tool" 2>&1 || true)"
  if grep -Eq 'lib(ncurses|tinfo)\.so\.5 => not found' <<<"$tool_deps"; then
    local old_rpath
    old_rpath="$("$PATCHELF_BIN" --print-rpath "$resolved_tool" 2>/dev/null || true)"

    # Prepend the compatibility-library directory and preserve all other
    # existing RPATH entries, avoiding duplicate entries on every watcher pass.
    local new_rpath="$NCURSES_LIBRARY_DIR"
    local old_part
    local -a rpath_parts=()
    IFS=':' read -r -a rpath_parts <<< "$old_rpath"
    for old_part in "${rpath_parts[@]}"; do
      [[ -z "$old_part" || "$old_part" == "$NCURSES_LIBRARY_DIR" ]] && continue
      new_rpath="$new_rpath:$old_part"
    done

    echo "Patching legacy ncurses RPATH for generated Soong host tool: $host_tool -> $resolved_tool"
    "$PATCHELF_BIN" --force-rpath --set-rpath "$new_rpath" "$resolved_tool"
    tool_deps="$(env -u LD_LIBRARY_PATH ldd "$resolved_tool" 2>&1 || true)"
    if grep -Eq 'lib(ncurses|tinfo)\.so\.5 => not found' <<<"$tool_deps"; then
      echo "::error::ncurses5/tinfo5 remain unresolved without LD_LIBRARY_PATH for $host_tool ($resolved_tool)"
      echo "$tool_deps"
      return 1
    fi
    if grep -q 'not found' <<<"$tool_deps"; then
      echo "::error::Other unresolved dependencies remain for $host_tool ($resolved_tool)"
      echo "$tool_deps"
      return 1
    fi
  fi
}

patch_soong_host_tools() {
  [[ -d "$SOONG_HOST_BIN" ]] || return 0

  # Do not filter with find's -executable predicate: the generated entries can
  # be symlinks, and that predicate can skip the exact llvm-tblgen link we need.
  while IFS= read -r -d '' host_tool; do
    patch_one_soong_tool "$host_tool" || return 1
  done < <(find "$SOONG_HOST_BIN" -maxdepth 1 \( -type f -o -type l \) -print0 2>/dev/null)

  # Explicitly inspect the known TableGen launchers even if find behaves
  # differently for symlinks on the host filesystem.
  patch_one_soong_tool "$SOONG_HOST_BIN/llvm-tblgen" || return 1
  patch_one_soong_tool "$SOONG_HOST_BIN/clang-tblgen" || return 1

  # Never perform the incremental retry unless the launcher named in the
  # observed build error can now resolve the legacy ncurses/tinfo libraries.
  if [[ -x "$SOONG_HOST_BIN/llvm-tblgen" ]]; then
    local resolved_tblgen
    resolved_tblgen="$(readlink -f "$SOONG_HOST_BIN/llvm-tblgen" 2>/dev/null || true)"
    if [[ -n "$resolved_tblgen" && -f "$resolved_tblgen" ]]; then
      local tblgen_deps
      # Match Ninja's sanitized environment; check RPATH without LD_LIBRARY_PATH.
      tblgen_deps="$(env -u LD_LIBRARY_PATH ldd "$resolved_tblgen" 2>&1 || true)"
      if grep -Eq 'lib(ncurses|tinfo)\.so\.5 => not found' <<<"$tblgen_deps"; then
        echo "::error::llvm-tblgen still cannot resolve ncurses5/tinfo5; refusing to repeat the same failed build."
        echo "$tblgen_deps"
        return 1
      fi
    fi
  fi
}
(
  while :; do
    patch_soong_host_tools || exit 1
    sleep 0.15
  done
) &
SOONG_PATCH_WATCHER_PID=$!
cleanup_soong_watcher() {
  kill "$SOONG_PATCH_WATCHER_PID" 2>/dev/null || true
  wait "$SOONG_PATCH_WATCHER_PID" 2>/dev/null || true
}
trap cleanup_soong_watcher EXIT

echo "Starting ROM compilation..."
BUILD_LOG="/tmp/iyad-aziez-build.log"
set +e
eval "$BUILD_COMMAND" 2>&1 | tee "$BUILD_LOG"
BUILD_STATUS=${PIPESTATUS[0]}
set -e

# A newly generated Soong llvm-tblgen can be invoked before the background
# watcher sees its symlink. If that exact old-library error occurs, patch all
# generated tool targets and retry once; the existing outputs make this an
# incremental retry rather than a clean rebuild.
if [[ "$BUILD_STATUS" -ne 0 ]] && grep -Eq 'lib(ncurses|tinfo)\.so\.5: cannot open shared object file|error while loading shared libraries: lib(ncurses|tinfo)\.so\.5' "$BUILD_LOG"; then
  echo "Legacy ncurses error detected. Patching generated Soong tools before one incremental retry."
  if ! patch_soong_host_tools; then
    echo "::error::Could not repair generated Soong tool dependencies; refusing an unpatched retry."
    exit 25
  fi
  set +e
  eval "$BUILD_COMMAND" 2>&1 | tee -a "$BUILD_LOG"
  BUILD_STATUS=${PIPESTATUS[0]}
  set -e
fi

if [[ "$BUILD_STATUS" -ne 0 ]]; then
  echo "::error::ROM build failed with exit code $BUILD_STATUS."
  exit "$BUILD_STATUS"
fi

OUTPUT_DIR="out/target/product/$DEVICE_NAME"
ROM_ZIP="$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.zip' -print -quit 2>/dev/null || true)"
if [[ -z "$ROM_ZIP" ]]; then
  echo "::error::Build command completed but no flashable ZIP was found in $OUTPUT_DIR."
  ls -lah "$OUTPUT_DIR" 2>/dev/null || true
  exit 22
fi
echo "Build produced flashable ZIP(s):"
find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.zip' -print
