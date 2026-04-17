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

# ─── Step 1: Clean if requested ───────────────────────────────────────
if [ "$CLEAN" = true ]; then
    echo ""
    echo "[1/5] Cleaning previous build..."
    swift package clean
    rm -rf "$PROJECT_DIR/dist"
else
    echo ""
    echo "[1/5] Skipping clean (use --clean to force)"
fi

# ─── Step 2: Release build ────────────────────────────────────────────
echo ""
echo "[2/5] Building release binary..."
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
echo "[3/5] Creating .app bundle..."

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

# Bundle ffmpeg if available (prefer ffmpeg-full which has libass for subtitles)
FFMPEG_PATH=""
for path in /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
    if [ -x "$path" ]; then
        FFMPEG_PATH="$path"
        break
    fi
done

if [ -n "$FFMPEG_PATH" ]; then
    echo "  Bundling ffmpeg from $FFMPEG_PATH"
    cp "$FFMPEG_PATH" "$APP_BUNDLE/Contents/Frameworks/ffmpeg"
    chmod +x "$APP_BUNDLE/Contents/Frameworks/ffmpeg"

    # Also bundle ffprobe if available
    FFPROBE_PATH="${FFMPEG_PATH/ffmpeg/ffprobe}"
    if [ -x "$FFPROBE_PATH" ]; then
        cp "$FFPROBE_PATH" "$APP_BUNDLE/Contents/Frameworks/ffprobe"
        chmod +x "$APP_BUNDLE/Contents/Frameworks/ffprobe"
        echo "  Bundling ffprobe from $FFPROBE_PATH"
    fi
else
    echo "  WARNING: ffmpeg not found — app will use system ffmpeg at runtime"
fi

APP_SIZE=$(du -sh "$APP_BUNDLE" | cut -f1)
echo "  App bundle: $APP_BUNDLE ($APP_SIZE)"

# ─── Step 4: Ad-hoc sign (allows running without Developer ID) ───────
echo ""
echo "[4/5] Ad-hoc signing..."
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || echo "  codesign not available, skipping"

# ─── Step 5: Create DMG (optional) ───────────────────────────────────
if [ "$MAKE_DMG" = true ]; then
    echo ""
    echo "[5/5] Creating DMG..."

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
    echo "[5/5] Skipping DMG (use --dmg to create)"
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
