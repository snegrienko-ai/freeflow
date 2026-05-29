#!/usr/bin/env bash
# build-dmg.sh — Autonomous DMG builder for FreeFlow.
# Uses only hdiutil + osascript. No create-dmg dependency.
set -euo pipefail

# ── Arguments ────────────────────────────────────────────────────────────────
APP_NAME="${1:?Usage: build-dmg.sh <APP_NAME> <BUILD_DIR> <ICON_ICNS> <BACKGROUND>}"
BUILD_DIR="${2:?Missing BUILD_DIR}"
ICON_ICNS="${3:?Missing ICON_ICNS}"
BACKGROUND="${4:-}"

APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
DMG_PATH="${BUILD_DIR}/${APP_NAME}.dmg"
STAGING="${BUILD_DIR}/dmg-staging"
VOLUME_NAME="${APP_NAME}"

# ── Validate inputs ─────────────────────────────────────────────────────────
if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "ERROR: App bundle not found: $APP_BUNDLE" >&2
  exit 1
fi

# ── Clean previous artifacts ─────────────────────────────────────────────────
rm -f "$DMG_PATH"
rm -rf "$STAGING"
mkdir -p "$STAGING"

# ── Stage the app ────────────────────────────────────────────────────────────
cp -R "$APP_BUNDLE" "$STAGING/"

# ── Create Applications symlink ──────────────────────────────────────────────
echo "Creating Applications link…"
ln -s /Applications "$STAGING/Applications"

# ── Create a writable sparse image (needed to customize layout) ──────────────
SPARSEIMAGE="${BUILD_DIR}/dmg-temp.sparseimage"
rm -f "$SPARSEIMAGE"

# Calculate size: app bundle size + 10 MB overhead
APP_SIZE_KB=$(du -sk "$STAGING" | awk '{print $1}')
IMAGE_SIZE_MB=$(( (APP_SIZE_KB / 1024) + 10 ))

echo "Creating sparse image (${IMAGE_SIZE_MB} MB)…"
hdiutil create \
  -size "${IMAGE_SIZE_MB}m" \
  -fs "HFS+" \
  -volname "$VOLUME_NAME" \
  -type SPARSE \
  "$SPARSEIMAGE" >/dev/null

# ── Mount the sparse image ──────────────────────────────────────────────────
echo "Mounting sparse image…"
MOUNT_POINT=$(hdiutil attach "$SPARSEIMAGE" -nobrowse -noautoopen | grep '/Volumes/' | sed 's/.*\t\(\/Volumes\/.*\)/\1/')

for item in "$STAGING"/*; do
  base=$(basename "$item")
  if [ -L "$item" ]; then
    ln -s "$(readlink "$item")" "$MOUNT_POINT/$base"
  else
    cp -R "$item" "$MOUNT_POINT/$base"
  fi
done

# ── Customize Finder window via AppleScript ──────────────────────────────────
echo "Customizing DMG window layout…"

customize_dmg_window() {
  osascript <<APPLESCRIPT
with timeout of 60 seconds
  tell application "Finder"
    tell disk "$VOLUME_NAME"
      open
      delay 3
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {200, 120, 860, 520}
      set theViewOptions to the icon view options of container window
      set arrangement of theViewOptions to not arranged
      set icon size of theViewOptions to 128
      set shows icon preview of theViewOptions to true
      set text size of theViewOptions to 12
      set position of item "${APP_NAME}.app" of container window to {180, 170}
      set position of item "Applications" of container window to {480, 170}
      delay 1
      set extension hidden of item "${APP_NAME}.app" of container window to true
      delay 1
      close
      open
      delay 1
      close
    end tell
  end tell
end timeout
APPLESCRIPT
}

MAX_RETRIES=3
RETRY=0
while [ "$RETRY" -lt "$MAX_RETRIES" ]; do
  if customize_dmg_window 2>/dev/null; then
    break
  fi
  RETRY=$((RETRY + 1))
  echo "  Finder timeout, retry ${RETRY}/${MAX_RETRIES}..."
  sleep 2
done
if [ "$RETRY" -eq "$MAX_RETRIES" ]; then
  echo "  Skipping window layout (Finder unresponsive). DMG is still functional."
fi

# ── Set background image (if provided) ───────────────────────────────────────
if [[ -n "$BACKGROUND" && -f "$BACKGROUND" ]]; then
  echo "Setting background image…"
  mkdir -p "$MOUNT_POINT/.background"
  cp "$BACKGROUND" "$MOUNT_POINT/.background/"
  BG_FILENAME=$(basename "$BACKGROUND")

  osascript -e "
    with timeout of 60 seconds
    tell application \"Finder\"
      tell disk \"$VOLUME_NAME\"
        open
        delay 2
        tell container window
          set current view to icon view
          set background picture to file \".background:${BG_FILENAME}\"
        end tell
        delay 1
        close
      end tell
    end tell
    end timeout
  " 2>/dev/null || echo "  Background image skipped (Finder unresponsive)."
fi

if [[ -f "$ICON_ICNS" ]]; then
  echo "Setting DMG icon…"
  cp "$ICON_ICNS" "$MOUNT_POINT/.VolumeIcon.icns"
  SetFile -a C "$MOUNT_POINT" 2>/dev/null || true
  sleep 1
fi

# ── Unmount ──────────────────────────────────────────────────────────────────
echo "Unmounting…"
hdiutil detach "$MOUNT_POINT" -quiet

# ── Convert to compressed read-only DMG ──────────────────────────────────────
echo "Converting to compressed DMG…"
hdiutil convert "$SPARSEIMAGE" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH" >/dev/null

# ── Cleanup ──────────────────────────────────────────────────────────────────
rm -f "$SPARSEIMAGE" "${SPARSEIMAGE}.shadow" 2>/dev/null || true
rm -rf "$STAGING"

echo "Created $DMG_PATH"
