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
echo "Starting ROM compilation..."
eval "$BUILD_COMMAND"

OUTPUT_DIR="out/target/product/$DEVICE_NAME"
ROM_ZIP="$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.zip' -print -quit 2>/dev/null || true)"
if [[ -z "$ROM_ZIP" ]]; then
  echo "::error::Build command completed but no flashable ZIP was found in $OUTPUT_DIR."
  ls -lah "$OUTPUT_DIR" 2>/dev/null || true
  exit 22
fi
echo "Build produced flashable ZIP(s):"
find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.zip' -print
