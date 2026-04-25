#!/bin/bash
set -euo pipefail

# ─── Scribe Build Script ───────────────────────────────────────
# Builds a release binary, packages it into a .app bundle,
# optionally bundles ffmpeg, and creates a DMG for distribution.
#
# Usage:
#   ./scripts/build-app.sh              # Build .app only
#   ./scripts/build-app.sh --dmg        # Build .app + DMG
#   ./scripts/build-app.sh --clean      # Clean build first

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP_NAME="Scribe"
APP_BUNDLE="$PROJECT_DIR/dist/$APP_NAME.app"
DMG_PATH="$PROJECT_DIR/dist/$APP_NAME.dmg"
VERSION="1.0.0"

MAKE_DMG=false
CLEAN=false

for arg in "$@"; do
    case "$arg" in
        --dmg)   MAKE_DMG=true ;;
        --clean) CLEAN=true ;;
    esac
done

echo "═══════════════════════════════════════════"
echo "  Scribe Build Script v$VERSION"
echo "═══════════════════════════════════════════"

# ─── Preflight: required toolchain ────────────────────────────────────
# We must be able to produce a fully self-contained .app — no silent
# fallback to system ffmpeg at runtime. Fail early if any piece is missing.

FFMPEG_PATH=""
for path in /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
    if [ -x "$path" ]; then
        FFMPEG_PATH="$path"
        break
    fi
done

if [ -z "$FFMPEG_PATH" ]; then
    echo ""
    echo "ERROR: ffmpeg not found on the build host."
    echo "       The .app must ship with a bundled ffmpeg (libass required for subtitle burning)."
    echo "       Install with: brew install ffmpeg-full"
    exit 1
fi

FFPROBE_PATH="$(dirname "$FFMPEG_PATH")/ffprobe"
if [ ! -x "$FFPROBE_PATH" ]; then
    echo ""
    echo "ERROR: ffprobe not found alongside ffmpeg at $FFPROBE_PATH"
    echo "       ffprobe is used to read video duration for composition progress."
    echo "       Install with: brew install ffmpeg-full"
    exit 1
fi

# Verify the host's ffmpeg actually runs. ffmpeg-full's binary bakes in the
# exact dylib version it was built against (e.g. libx265.215). If any of
# those Homebrew packages have been upgraded since (e.g. x265 → libx265.216),
# the host ffmpeg is already broken and dylibbundler will infinite-loop on
# the missing dep. Catch that here with a clear remediation.
if ! "$FFMPEG_PATH" -version >/dev/null 2>&1; then
    echo ""
    echo "ERROR: $FFMPEG_PATH cannot run on this host."
    echo "       Likely cause: a Homebrew dep has been upgraded past the version"
    echo "       ffmpeg-full was linked against. dyld error:"
    "$FFMPEG_PATH" -version 2>&1 | sed 's/^/         /' | head -5
    echo ""
    echo "       Fix: brew reinstall ffmpeg-full"
    exit 1
fi

if ! command -v dylibbundler >/dev/null 2>&1; then
    echo ""
    echo "ERROR: dylibbundler not found."
    echo "       Required to copy Homebrew dylibs into the .app and rewrite install_names."
    echo "       Without it the bundled ffmpeg will fail at runtime with 'Library not loaded'."
    echo "       Install with: brew install dylibbundler"
    exit 1
fi

# ─── Step 1: Clean if requested ───────────────────────────────────────
if [ "$CLEAN" = true ]; then
    echo ""
    echo "[1/6] Cleaning previous build..."
    swift package clean
    rm -rf "$PROJECT_DIR/dist"
else
    echo ""
    echo "[1/6] Skipping clean (use --clean to force)"
fi

# ─── Step 2: Release build ────────────────────────────────────────────
echo ""
echo "[2/6] Building release binary..."
cd "$PROJECT_DIR"
swift build -c release 2>&1

BINARY="$BUILD_DIR/Scribe"
if [ ! -f "$BINARY" ]; then
    echo "ERROR: Build failed — binary not found at $BINARY"
    exit 1
fi

BINARY_SIZE=$(du -h "$BINARY" | cut -f1)
echo "  Binary: $BINARY ($BINARY_SIZE)"

# ─── Step 3: Create .app bundle ──────────────────────────────────────
echo ""
echo "[3/6] Creating .app bundle..."

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

# Copy binary
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy Info.plist
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/"

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Bundle app icon (generate if missing)
if [ ! -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    echo "  Generating app icon..."
    "$PROJECT_DIR/scripts/make-icon.sh"
fi
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
echo "  Bundled app icon"

# Copy ffmpeg + ffprobe to Contents/MacOS/ alongside the main binary.
# Keeping helper binaries OUT of Frameworks/ matters for dylibbundler:
# it treats --dest-dir as its working set, and when a --fix-file lives
# inside that same set it gets confused and silently drops it.
echo "  Copying ffmpeg from $FFMPEG_PATH"
cp "$FFMPEG_PATH" "$APP_BUNDLE/Contents/MacOS/ffmpeg"
chmod +x "$APP_BUNDLE/Contents/MacOS/ffmpeg"

echo "  Copying ffprobe from $FFPROBE_PATH"
cp "$FFPROBE_PATH" "$APP_BUNDLE/Contents/MacOS/ffprobe"
chmod +x "$APP_BUNDLE/Contents/MacOS/ffprobe"

APP_SIZE=$(du -sh "$APP_BUNDLE" | cut -f1)
echo "  App bundle: $APP_BUNDLE ($APP_SIZE)"

# ─── Step 4: Bundle dylibs ────────────────────────────────────────────
# ffmpeg-full is dynamically linked to ~60 Homebrew dylibs. Copying just
# the ffmpeg binary leaves every dylib reference pointing at the build
# host's /opt/homebrew path — which breaks on any end-user machine.
# dylibbundler recursively copies the dylibs into Frameworks/ and
# rewrites each install_name to @executable_path/../Frameworks/ so
# both ffmpeg (in MacOS/) and the dylibs themselves (in Frameworks/)
# resolve their deps relative to the running process.
echo ""
echo "[4/6] Bundling Homebrew dylibs via dylibbundler..."

DYLIBBUNDLER_LOG="$PROJECT_DIR/dist/dylibbundler.log"
# Redirect stdin to /dev/null so dylibbundler can never hang on its
# interactive "Please specify the directory" prompt — give it immediate
# EOF and let it fail fast if a dylib is unresolvable.
dylibbundler \
    --overwrite-dir \
    --overwrite-files \
    --bundle-deps \
    --create-dir \
    --no-codesign \
    --fix-file "$APP_BUNDLE/Contents/MacOS/ffmpeg" \
    --fix-file "$APP_BUNDLE/Contents/MacOS/ffprobe" \
    --dest-dir "$APP_BUNDLE/Contents/Frameworks/" \
    --install-path "@executable_path/../Frameworks/" \
    </dev/null >"$DYLIBBUNDLER_LOG" 2>&1 || {
        echo "ERROR: dylibbundler failed. Last 30 lines of log:"
        tail -30 "$DYLIBBUNDLER_LOG"
        echo ""
        echo "       Full log: $DYLIBBUNDLER_LOG"
        exit 1
    }

DYLIB_COUNT=$(find "$APP_BUNDLE/Contents/Frameworks" -name "*.dylib" | wc -l | tr -d ' ')
echo "  Bundled $DYLIB_COUNT dylibs"

# Sanity check — no reference to /opt/homebrew or /usr/local should remain.
LEAKED=$(otool -L "$APP_BUNDLE/Contents/MacOS/ffmpeg" \
    "$APP_BUNDLE/Contents/MacOS/ffprobe" \
    "$APP_BUNDLE"/Contents/Frameworks/*.dylib 2>/dev/null \
    | grep -E "(/opt/homebrew|/usr/local/(opt|Cellar))" || true)
if [ -n "$LEAKED" ]; then
    echo "ERROR: bundled binaries still reference external Homebrew paths:"
    echo "$LEAKED"
    exit 1
fi

APP_SIZE=$(du -sh "$APP_BUNDLE" | cut -f1)
echo "  App bundle: $APP_BUNDLE ($APP_SIZE)"

# ─── Step 5: Ad-hoc sign (allows running without Developer ID) ───────
# Must run AFTER dylibbundler, which modifies install_names and would
# otherwise invalidate the signatures.
echo ""
echo "[5/6] Ad-hoc signing..."
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || echo "  codesign not available, skipping"

# ─── Step 6: Create DMG (optional) ───────────────────────────────────
if [ "$MAKE_DMG" = true ]; then
    echo ""
    echo "[6/6] Creating DMG..."

    rm -f "$DMG_PATH"

    # Create a temporary directory for DMG contents
    DMG_TMP="$PROJECT_DIR/dist/dmg_tmp"
    rm -rf "$DMG_TMP"
    mkdir -p "$DMG_TMP"
    cp -R "$APP_BUNDLE" "$DMG_TMP/"

    # Create a symlink to /Applications
    ln -s /Applications "$DMG_TMP/Applications"

    # Create DMG
    hdiutil create \
        -volname "$APP_NAME" \
        -srcfolder "$DMG_TMP" \
        -ov \
        -format UDZO \
        "$DMG_PATH" 2>/dev/null

    rm -rf "$DMG_TMP"

    DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
    echo "  DMG: $DMG_PATH ($DMG_SIZE)"
else
    echo ""
    echo "[6/6] Skipping DMG (use --dmg to create)"
fi

# ─── Done ─────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════"
echo "  Build complete!"
echo ""
echo "  .app:  $APP_BUNDLE"
if [ "$MAKE_DMG" = true ]; then
    echo "  .dmg:  $DMG_PATH"
fi
echo ""
echo "  To run:  open $APP_BUNDLE"
echo "═══════════════════════════════════════════"
