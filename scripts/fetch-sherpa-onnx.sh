#!/bin/bash
set -euo pipefail

# ─── Fetch sherpa-onnx XCFramework + Swift wrapper ─────────────────────
# Downloads the prebuilt sherpa-onnx macOS xcframework from the upstream
# GitHub release and the matching Swift wrapper file from the same tag.
# Both go into vendor/ (gitignored). Idempotent — re-runs are no-ops if
# the xcframework directory is already present.
#
# Why this exists:
#   sherpa-onnx does not publish a SwiftPM-friendly artifact, only a
#   tarball on its release page. We don't want a 30+ MB binary blob in
#   git history, so we keep the artifact out of the repo and have every
#   fresh checkout pull it once.
#
# Usage:
#   ./scripts/fetch-sherpa-onnx.sh         # fetch if missing
#   ./scripts/fetch-sherpa-onnx.sh --force # re-fetch even if present

SHERPA_VERSION="v1.13.0"
# sherpa-onnx ${SHERPA_VERSION}'s macOS static lib is built against a
# **specific** ONNX Runtime version (see cmake/onnxruntime-osx-universal-static.cmake
# in the upstream repo at this tag). Mixing in an older ORT triggers a
# silent ABI mismatch — Ort::Env's vtable layout has changed across
# versions, and the resulting null-vtable read inside Env::Env() segfaults
# during recognizer construction. Track upstream when bumping SHERPA_VERSION.
ORT_VERSION="1.24.4"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$PROJECT_DIR/vendor"
XCF_NAME="sherpa-onnx.xcframework"
XCF_DIR="$VENDOR_DIR/$XCF_NAME"
ORT_NAME="onnxruntime.xcframework"
ORT_DIR="$VENDOR_DIR/$ORT_NAME"
WRAPPER_DIR="$VENDOR_DIR/sherpa-onnx-swift"

TARBALL_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/${SHERPA_VERSION}/sherpa-onnx-${SHERPA_VERSION}-macos-xcframework-static.tar.bz2"
# The sherpa-onnx tarball does **not** bundle ONNX Runtime — its upstream
# build script links `-l sherpa-onnx -l onnxruntime` separately. We pull
# the matching ONNX Runtime universal2 static lib from csukuangfj's
# pre-built release archive (same source the sherpa-onnx CMake fetches at
# build time).
ORT_ZIP_URL="https://github.com/csukuangfj/onnxruntime-libs/releases/download/v${ORT_VERSION}/onnxruntime-osx-universal2-static_lib-${ORT_VERSION}.zip"
WRAPPER_URL="https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/${SHERPA_VERSION}/swift-api-examples/SherpaOnnx.swift"
HEADER_URL="https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/${SHERPA_VERSION}/swift-api-examples/SherpaOnnx-Bridging-Header.h"

FORCE=false
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
    esac
done

if [ "$FORCE" = false ] && [ -d "$XCF_DIR" ] && [ -d "$ORT_DIR" ] && [ -f "$WRAPPER_DIR/SherpaOnnx.swift" ]; then
    echo "sherpa-onnx already present at $XCF_DIR — skipping (use --force to re-fetch)"
    exit 0
fi

if [ "$FORCE" = true ]; then
    echo "[--force] removing previous vendor copies..."
    rm -rf "$XCF_DIR" "$ORT_DIR" "$WRAPPER_DIR"
fi

mkdir -p "$VENDOR_DIR" "$WRAPPER_DIR"

# ─── sherpa-onnx XCFramework ─────────────────────────────────────────
TARBALL_PATH="$VENDOR_DIR/sherpa-onnx-${SHERPA_VERSION}-macos.tar.bz2"
echo "[1/4] Downloading sherpa-onnx xcframework (~8.5 MB compressed)..."
curl -fL --progress-bar -o "$TARBALL_PATH" "$TARBALL_URL"

echo "[2/4] Extracting into $VENDOR_DIR..."
tar -xjf "$TARBALL_PATH" -C "$VENDOR_DIR"
rm -f "$TARBALL_PATH"

# Upstream tarballs occasionally extract into a versioned wrapper directory.
# Detect that and flatten if needed so the final path is always
# vendor/sherpa-onnx.xcframework/.
if [ ! -d "$XCF_DIR" ]; then
    found=$(find "$VENDOR_DIR" -maxdepth 3 -type d -name "$XCF_NAME" -print -quit || true)
    if [ -z "$found" ]; then
        echo "ERROR: $XCF_NAME not found after extraction. Tarball layout may have changed."
        exit 1
    fi
    if [ "$found" != "$XCF_DIR" ]; then
        echo "  Moving $found → $XCF_DIR"
        mv "$found" "$XCF_DIR"
    fi
fi
# Drop the now-empty wrapper dir from the tarball.
find "$VENDOR_DIR" -maxdepth 1 -type d -name "sherpa-onnx-${SHERPA_VERSION}-macos-xcframework-static" -exec rm -rf {} + 2>/dev/null || true

# ─── ONNX Runtime XCFramework (built from csukuangfj prebuilt zip) ───
# The macos xcframework above leaves OrtGetApiBase as an undefined extern.
# Upstream's run-decode-file.sh links `-l sherpa-onnx -l onnxruntime`. We
# pull the matching ONNX Runtime universal2 static-lib zip and then wrap
# it in a single-slice xcframework via `xcodebuild -create-xcframework`,
# which produces a clean Info.plist with no symlink quirks.
ORT_ZIP_PATH="$VENDOR_DIR/onnxruntime-osx-universal2-static_lib-${ORT_VERSION}.zip"
echo "[3/4] Downloading ONNX Runtime ${ORT_VERSION} (~34 MB compressed)..."
curl -fL --progress-bar -o "$ORT_ZIP_PATH" "$ORT_ZIP_URL"

EXTRACT_TMP="$VENDOR_DIR/_ort_extract"
rm -rf "$EXTRACT_TMP"
mkdir -p "$EXTRACT_TMP"
unzip -q "$ORT_ZIP_PATH" -d "$EXTRACT_TMP"
rm -f "$ORT_ZIP_PATH"

ORT_INTERNAL="$EXTRACT_TMP/onnxruntime-osx-universal2-static_lib-${ORT_VERSION}"
if [ ! -f "$ORT_INTERNAL/lib/libonnxruntime.a" ]; then
    echo "ERROR: libonnxruntime.a not found in $ORT_INTERNAL — zip layout changed?"
    rm -rf "$EXTRACT_TMP"
    exit 1
fi

# Build a fresh xcframework wrapping just the single universal2 .a +
# headers. xcodebuild produces the Info.plist correctly itself.
rm -rf "$ORT_DIR"
xcodebuild -create-xcframework \
    -library "$ORT_INTERNAL/lib/libonnxruntime.a" \
    -headers "$ORT_INTERNAL/include" \
    -output "$ORT_DIR" >/dev/null

rm -rf "$EXTRACT_TMP"

# ─── Inject module.modulemap so SwiftPM can import the C API ─────────
# The upstream xcframework ships only headers + a static .a; SwiftPM's
# .binaryTarget needs a Clang module map to expose the C symbols to
# Swift. We synthesize it here (kept inside vendor/ so it's regenerated
# on every fresh fetch).
MODMAP_DIR="$XCF_DIR/macos-arm64_x86_64/Headers"
cat > "$MODMAP_DIR/module.modulemap" <<'EOF'
module CSherpaOnnx {
    umbrella header "sherpa-onnx/c-api/c-api.h"
    export *
    link "c++"
}
EOF

# ─── Swift wrapper + bridging header ─────────────────────────────────
echo "[4/4] Downloading Swift wrapper & bridging header..."
curl -fL --progress-bar -o "$WRAPPER_DIR/SherpaOnnx.swift" "$WRAPPER_URL"
curl -fL --progress-bar -o "$WRAPPER_DIR/SherpaOnnx-Bridging-Header.h" "$HEADER_URL"

XCF_SIZE=$(du -sh "$XCF_DIR" | cut -f1)
ORT_SIZE=$(du -sh "$ORT_DIR" | cut -f1)
WRAPPER_SIZE=$(du -sh "$WRAPPER_DIR" | cut -f1)

echo ""
echo "═══════════════════════════════════════════"
echo "  sherpa-onnx ${SHERPA_VERSION} fetched"
echo ""
echo "  sherpa-onnx.xcframework:  $XCF_DIR ($XCF_SIZE)"
echo "  onnxruntime.xcframework:  $ORT_DIR ($ORT_SIZE)"
echo "  Swift wrapper:            $WRAPPER_DIR ($WRAPPER_SIZE)"
echo "═══════════════════════════════════════════"
