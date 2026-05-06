#!/bin/bash
set -euo pipefail

# ─── Build mlx.metallib for mlx-swift ────────────────────────────────
# mlx-swift's `swift build` cannot compile Metal shaders (per its README:
# "SwiftPM (command line) cannot build the Metal shaders so the ultimate
# build has to be done via Xcode"). We do it ourselves here using
# `xcrun metal` + `xcrun metallib`, then drop the result next to the
# Scribe binary so MLX's `load_colocated_library("mlx")` finds it.
#
# Background — only AOT kernels need to be in the metallib:
# Most MLX kernels are JIT-compiled at runtime from C++ string literals
# in `mlx-generated/` (already built into the binary). The handful below
# live outside the JIT path and must be precompiled. Mirrors the
# unconditional `build_kernel(...)` calls in
# Source/Cmlx/mlx/mlx/backend/metal/kernels/CMakeLists.txt.
#
# Usage:
#   ./scripts/build-mlx-metallib.sh <output-metallib-path>
#
# Requires: full Xcode (Command Line Tools alone do NOT include the Metal
# compiler). If `xcrun metal` is not available the script exits with a
# clear error so the surrounding .app build fails fast.

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <output-metallib-path>" >&2
    exit 2
fi

OUTPUT_PATH="$1"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MLX_DIR="$PROJECT_DIR/.build/checkouts/mlx-swift/Source/Cmlx/mlx"
KERNELS_DIR="$MLX_DIR/mlx/backend/metal/kernels"

# ─── Preflight ────────────────────────────────────────────────────────
if [ ! -d "$KERNELS_DIR" ]; then
    echo "ERROR: MLX kernels not found at $KERNELS_DIR" >&2
    echo "       Did 'swift package resolve' run successfully?" >&2
    exit 1
fi

if ! xcrun -sdk macosx --find metal >/dev/null 2>&1; then
    echo "" >&2
    echo "ERROR: 'xcrun metal' is unavailable on this host." >&2
    echo "       The Metal shader compiler ships with full Xcode (App Store)," >&2
    echo "       not Command Line Tools. Without it the 1.7B engine cannot run." >&2
    echo "" >&2
    echo "       Fix: install Xcode, then point xcode-select at it:" >&2
    echo "         sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    exit 1
fi

# ─── Kernel list ─────────────────────────────────────────────────────
# Kernels that must be AOT-compiled into mlx.metallib.
# Path is relative to $KERNELS_DIR; suffix is implied to be ".metal".
KERNELS=(
    arg_reduce
    conv
    gemv
    layer_norm
    random
    rms_norm
    rope
    scaled_dot_product_attention
    fence
)

# Macro deployment target for Metal — keep in sync with Package.swift.
METAL_DEPLOYMENT_TARGET="15.0"

# Mirror the flags from kernels/CMakeLists.txt build_kernel_base()
METAL_FLAGS=(
    -x metal
    -Wall -Wextra
    -fno-fast-math
    -Wno-c++17-extensions
    -Wno-c++20-extensions
    "-mmacosx-version-min=$METAL_DEPLOYMENT_TARGET"
)

# ─── Build ────────────────────────────────────────────────────────────
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

AIR_FILES=()
echo "  Compiling $(echo "${#KERNELS[@]}") metal kernels..."
for kernel in "${KERNELS[@]}"; do
    src="$KERNELS_DIR/$kernel.metal"
    if [ ! -f "$src" ]; then
        echo "    WARN: $kernel.metal not found at $src — skipping" >&2
        continue
    fi
    air="$TMP_DIR/$(basename "$kernel").air"
    echo "    $kernel.metal -> $(basename "$air")"
    xcrun -sdk macosx metal "${METAL_FLAGS[@]}" \
        -c "$src" -I "$MLX_DIR" -o "$air"
    AIR_FILES+=("$air")
done

if [ "${#AIR_FILES[@]}" -eq 0 ]; then
    echo "ERROR: no .air files produced" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
echo "  Linking ${#AIR_FILES[@]} .air files -> $(basename "$OUTPUT_PATH")"
xcrun -sdk macosx metallib "${AIR_FILES[@]}" -o "$OUTPUT_PATH"

METALLIB_SIZE=$(du -h "$OUTPUT_PATH" | cut -f1)
echo "  metallib: $OUTPUT_PATH ($METALLIB_SIZE)"
