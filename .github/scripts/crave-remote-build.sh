#!/usr/bin/env bash
# Build LineageOS 18.1 (Android 11) for Samsung Galaxy Tab A SM-T355Y (gt58lte) on Crave.
#
# Main change versus the previous script: the old "watcher" loop (ldd on every
# file every 0.15s) was a race. Soong links llvm-tblgen and immediately runs it,
# so the tool was often used before the watcher patched it. This version:
#   1. builds the TableGen host tools first and patches them,
#   2. runs the real build,
#   3. if the libncurses.so.5 / libtinfo.so.5 error still appears, patches every
#      host tool that needs those libraries and retries (incremental, max 6).
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

MAX_ATTEMPTS=6
BUILD_LOG="/tmp/iyad-aziez-build.log"

echo "=== IYAD AZIEZ OS build preflight ==="
echo "Workspace: $(pwd)"
echo "Device: $DEVICE_NAME"
echo "Product: $PRODUCT_NAME"
if [[ ! -d .repo ]]; then
  echo "::error::No initialized Android .repo directory in the Crave workspace."
  exit 10
fi

# ---------------------------------------------------------------------------
# 1. Manifest + sync
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 2. Device tree validation and small fixes
# ---------------------------------------------------------------------------
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

# Do not fabricate an empty regional kernel defconfig: it can silently omit
# device-specific kernel options and produce a build that boots incorrectly.
# Require the exact SM-T355Y/Australia variant config referenced by this device tree.
if [[ "$DEVICE_NAME" == "gt58lte" ]]; then
  AUS_VARIANT_CONFIG="kernel/samsung/msm8916/arch/arm/configs/msm8916_sec_gt58lte_aus_defconfig"
  if [[ ! -s "$AUS_VARIANT_CONFIG" ]]; then
    echo "::error::Required SM-T355Y kernel config is missing or empty: $AUS_VARIANT_CONFIG"
    echo "Use a kernel branch that explicitly provides the gt58lte AUS config; do not substitute another model's config."
    exit 25
  fi
fi

# ---------------------------------------------------------------------------
# 2b. IYAD AZIEZ branding and conservative battery configuration
# ---------------------------------------------------------------------------
# Keep branding limited to the target product; do not overwrite Samsung model
# identifiers or copy files from a different tablet variant.
if [[ "$DEVICE_NAME" == "gt58lte" ]]; then
  DEVICE_DIR="device/samsung/$DEVICE_NAME"
  BRANDING_MK="$DEVICE_DIR/iyad_aziez_branding.mk"

  cat > "$BRANDING_MK" <<'EOF'
# IYAD AZIEZ OS product branding for Samsung Galaxy Tab A SM-T355Y.
# The custom boot animation is installed by the product makefile below.
PRODUCT_BRAND := Iyad Aziez
PRODUCT_MANUFACTURER := Iyad Aziez
PRODUCT_COPY_FILES += \
    device/samsung/gt58lte/bootanimation.zip:system/media/bootanimation.zip
EOF

  # Create a tiny, valid boot animation with a black background and a
  # centered "iyad aziez" logo. Use ImageMagick if the build host has it.
  # Keep frame count/resolution low to avoid increasing boot time or ZIP size.
  BOOTANIM_WORK="/tmp/iyad-aziez-bootanimation"
  mkdir -p "$BOOTANIM_WORK/part0"
  if command -v convert >/dev/null 2>&1; then
    convert -size 720x1280 xc:black -fill white -gravity center \
      -font DejaVu-Sans -pointsize 54 -annotate +0+0 'iyad aziez' \
      "$BOOTANIM_WORK/part0/00000.png"
    cp "$BOOTANIM_WORK/part0/00000.png" "$BOOTANIM_WORK/part0/00001.png"
    printf '720 1280 15\np 1 0 part0\n' > "$BOOTANIM_WORK/desc.txt"
    (cd "$BOOTANIM_WORK" && zip -q -0 -r "$PWD/bootanimation.zip" desc.txt part0)
    cp "$BOOTANIM_WORK/bootanimation.zip" "$DEVICE_DIR/bootanimation.zip"
  else
    echo "::warning::ImageMagick is unavailable; leaving the existing boot animation unchanged."
    rm -f "$BRANDING_MK"
  fi

  # Only include the branding makefile when its animation was generated.
  if [[ -s "$DEVICE_DIR/bootanimation.zip" && -s "$BRANDING_MK" ]]; then
    if ! grep -qF 'inherit-product, device/samsung/gt58lte/iyad_aziez_branding.mk' "$DEVICE_DIR/device.mk"; then
      printf '\n# IYAD AZIEZ OS branding\n$(call inherit-product, device/samsung/gt58lte/iyad_aziez_branding.mk)\n' >> "$DEVICE_DIR/device.mk"
    fi
    echo "Applied IYAD AZIEZ boot branding."
  fi

  # Do not fake root access with a property: LineageOS 18.1 must include a
  # compatible su implementation for an actual root toggle. Report the
  # supported path and leave the ROM build safe if no su package is configured.
  if ! grep -RqsE '(^|[[:space:]])(WITH_SU[[:space:]]*:?=|PRODUCT_PACKAGES.*\bsu\b|addonsu)' "$DEVICE_DIR"; then
    echo "::warning::No device-tree su implementation found. This build will not claim built-in root; add a compatible root solution after validating the ROM."
  fi

  # Battery-life improvements are device/kernel/HAL-specific. Avoid unsafe
  # guessed CPU-frequency, voltage, thermal, or wakelock tweaks in a build
  # script; verify that the target tree defines power profiles and a Power HAL.
  if [[ ! -d "device/samsung/$DEVICE_NAME" ]]; then
    echo "::error::Device tree disappeared before power configuration check."
    exit 26
  fi
  if ! grep -RqsE 'power_profile|PowerProfile|android.hardware.power|power.*\.xml' "device/samsung/$DEVICE_NAME"; then
    echo "::warning::No device-specific power profile was found by the basic check; battery optimization still needs device testing."
  fi
fi

# ---------------------------------------------------------------------------
# 3. Legacy ncurses5/tinfo5 libraries (needed by Android 11's old Clang/LLVM)
# ---------------------------------------------------------------------------
if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "::error::The ncurses compatibility packages are amd64-only; got $(uname -m)."
  exit 16
fi
if ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "::error::dpkg-deb is unavailable; cannot unpack the legacy compatibility libraries."
  exit 17
fi

fetch_file() {
  # fetch_file <dest-dir> <file-name> <base-url>...  (tries each base URL in order)
  local dest="$1" file="$2"
  shift 2
  [[ -s "$dest/$file" ]] && return 0
  local base
  for base in "$@"; do
    if curl --fail --location --retry 3 --connect-timeout 20 \
         "$base/$file" --output "$dest/$file"; then
      return 0
    fi
    rm -f "$dest/$file"
  done
  return 1
}

NCURSES_ROOT="$HOME/.cache/iyad-aziez/ncurses5"
NCURSES_PACKAGES="$NCURSES_ROOT/packages"
NCURSES_EXTRACT="$NCURSES_ROOT/root"
mkdir -p "$NCURSES_PACKAGES" "$NCURSES_EXTRACT"
UBUNTU_BASE="https://archive.ubuntu.com/ubuntu/pool"
for package in libtinfo5_6.2-0ubuntu2.1_amd64.deb libncurses5_6.2-0ubuntu2.1_amd64.deb; do
  if ! fetch_file "$NCURSES_PACKAGES" "$package" \
       "$UBUNTU_BASE/main/n/ncurses" "$UBUNTU_BASE/universe/n/ncurses"; then
    echo "::error::Could not download $package from archive.ubuntu.com."
    exit 18
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

# Android build tools sanitize LD_LIBRARY_PATH for child processes, so the path
# is also embedded as an ELF RPATH using patchelf.
PATCHELF_BIN="$(command -v patchelf || true)"
if [[ -z "$PATCHELF_BIN" ]]; then
  PATCHELF_ROOT="$HOME/.cache/iyad-aziez/patchelf"
  PATCHELF_DEB="patchelf_0.14.3-1+b1_amd64.deb"
  PATCHELF_EXTRACT="$PATCHELF_ROOT/root"
  mkdir -p "$PATCHELF_ROOT" "$PATCHELF_EXTRACT"
  fetch_file "$PATCHELF_ROOT" "$PATCHELF_DEB" \
    "https://deb.debian.org/debian/pool/main/p/patchelf" || true
  if [[ -s "$PATCHELF_ROOT/$PATCHELF_DEB" ]]; then
    dpkg-deb -f "$PATCHELF_ROOT/$PATCHELF_DEB" Architecture | grep -qx 'amd64'
    dpkg-deb -x "$PATCHELF_ROOT/$PATCHELF_DEB" "$PATCHELF_EXTRACT"
    PATCHELF_BIN="$(find "$PATCHELF_EXTRACT" -type f -name patchelf -print -quit)"
  fi
fi
if [[ -z "$PATCHELF_BIN" || ! -x "$PATCHELF_BIN" ]]; then
  echo "::error::Could not obtain patchelf to fix legacy compiler runtime paths."
  exit 24
fi

needs_legacy_ncurses() {
  local needed
  needed="$("$PATCHELF_BIN" --print-needed "$1" 2>/dev/null || true)"
  grep -Eq '^lib(ncurses|tinfo)\.so\.5$' <<<"$needed"
}

patch_tool() {
  # Add the legacy library dir to the RPATH of one ELF file, only if it needs it.
  local tool="$1" real old_rpath
  real="$(readlink -f "$tool" 2>/dev/null || true)"
  [[ -n "$real" && -f "$real" ]] || return 0
  needs_legacy_ncurses "$real" || return 0
  old_rpath="$("$PATCHELF_BIN" --print-rpath "$real" 2>/dev/null || true)"
  case ":$old_rpath:" in
    *":$NCURSES_LIBRARY_DIR:"*) return 0 ;;
  esac
  "$PATCHELF_BIN" --force-rpath --set-rpath "$NCURSES_LIBRARY_DIR${old_rpath:+:$old_rpath}" "$real"
  echo "Patched RPATH: $real"
}

patch_all_host_tools() {
  local dir tool
  for dir in out/soong/host/linux-x86/bin out/host/linux-x86/bin; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' tool; do
      patch_tool "$tool"
    done < <(find "$dir" -maxdepth 1 \( -type f -o -type l \) -print0 2>/dev/null)
  done
}

# Locate the Clang tools actually present in the synced source tree.
# Do not hard-code a prebuilt version number: Lineage branches use different names.
CLANG_BIN=""
while IFS= read -r -d '' candidate; do
  if [[ -x "$candidate/clang.real" && -x "$candidate/llvm-as" ]]; then
    CLANG_BIN="$candidate"
    break
  fi
done < <(find prebuilts/clang/host/linux-x86 -mindepth 2 -maxdepth 3 -type d -name bin -print0 2>/dev/null)
if [[ -z "$CLANG_BIN" ]]; then
  echo "::error::Could not find a Clang prebuilt bin directory containing both clang.real and llvm-as."
  find prebuilts/clang/host/linux-x86 -maxdepth 5 \( -name clang.real -o -name llvm-as \) -print 2>/dev/null || true
  exit 20
fi
echo "Using Clang tools from: $CLANG_BIN"
# Patch every executable in this Clang toolchain, especially llvm-link:
# RenderScript invokes llvm-link directly, and it also requires libncurses.so.5.
while IFS= read -r -d '' legacy_tool; do
  [[ -x "$legacy_tool" ]] || continue
  patch_tool "$legacy_tool"
done < <(find "$CLANG_BIN" -maxdepth 1 -type f -print0 2>/dev/null)

for legacy_tool in "$CLANG_BIN/clang.real" "$CLANG_BIN/llvm-as" "$CLANG_BIN/llvm-link"; do
  if [[ ! -x "$legacy_tool" ]]; then
    echo "::warning::Expected Clang tool not found: $legacy_tool"
    continue
  fi
  patch_tool "$legacy_tool"
  # Test without LD_LIBRARY_PATH so this validates the embedded RPATH itself.
  if env -u LD_LIBRARY_PATH ldd "$legacy_tool" 2>&1 | grep -q 'not found'; then
    echo "::error::Unresolved shared library dependency for $legacy_tool after RPATH patch."
    env -u LD_LIBRARY_PATH ldd "$legacy_tool" || true
    exit 21
  fi
done
echo "Legacy compiler dependencies are available."

# ---------------------------------------------------------------------------
# 4. Build
# ---------------------------------------------------------------------------
source build/envsetup.sh
eval "$LUNCH"
make installclean

: > "$BUILD_LOG"

run_build() {
  local status
  set +e
  eval "$1" 2>&1 | tee -a "$BUILD_LOG"
  status=${PIPESTATUS[0]}
  set -e
  return "$status"
}

# Phase 1: build the TableGen host tools alone and patch them before anything
# executes them. Best-effort: if it fails, the retry loop below handles it.
echo "Phase 1: building TableGen host tools first..."
if ! run_build "m llvm-tblgen clang-tblgen"; then
  echo "::warning::Phase 1 did not finish cleanly; continuing with the retry loop."
fi
patch_all_host_tools

# Phase 2: the real build, with an incremental retry if the ncurses5 error appears.
BUILD_STATUS=0
attempt=1
while true; do
  echo "=== Build attempt $attempt/$MAX_ATTEMPTS ==="
  log_start="$(wc -c < "$BUILD_LOG")"
  if run_build "$BUILD_COMMAND"; then
    BUILD_STATUS=0
    break
  else
    BUILD_STATUS=$?
  fi

  if tail -c +"$((log_start + 1))" "$BUILD_LOG" \
       | grep -Eq 'error while loading shared libraries: lib(ncurses|tinfo)\.so\.5' \
     && (( attempt < MAX_ATTEMPTS )); then
    echo "Legacy ncurses error detected. Patching generated host tools and retrying..."
    patch_all_host_tools
    attempt=$((attempt + 1))
    continue
  fi
  break
done

if [[ "$BUILD_STATUS" -ne 0 ]]; then
  echo "::error::ROM build failed with exit code $BUILD_STATUS (attempt $attempt)."
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