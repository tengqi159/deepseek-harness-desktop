#!/bin/bash

set -euo pipefail

MODE="${1:-run}"
APP_NAME="DeepSeek Harness"
PRODUCT_NAME="DeepSeekHarnessMac"
BUNDLE_ID="com.tengqi.deepseek-harness.desktop"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/app"
DIST_DIR="$(/usr/bin/mktemp -d /private/tmp/deepseek-harness-build.XXXXXX)"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
HELPER_BINARY="$APP_HELPERS/DeepSeekAppBridge"
ARTIFACT_HELPER_BINARY="$APP_HELPERS/DeepSeekArtifactBridge"
INFO_PLIST="$APP_CONTENTS/Info.plist"
OUTPUT_APP="$ROOT_DIR/outputs/$APP_NAME.app"
OUTPUT_ZIP="$ROOT_DIR/outputs/$APP_NAME.zip"
SYSTEM_INSTALLED_APP="/Applications/$APP_NAME.app"
USER_INSTALLED_APP="$HOME/Applications/$APP_NAME.app"
ICON_SOURCE="$PROJECT_DIR/Resources/AppIcon.svg"
ICONSET_DIR="$DIST_DIR/AppIcon.iconset"
ICON_MASTER="$DIST_DIR/AppIcon-1024.png"
ICON_FILE="$APP_RESOURCES/AppIcon.icns"
INTEGRATION_SOURCE="$ROOT_DIR/integration"
INTEGRATION_RESOURCES="$APP_RESOURCES/HarnessIntegration"
SIGNING_HELPER="$ROOT_DIR/scripts/ensure_local_signing_identity.sh"

SIGN_MODE="ad-hoc"
SIGN_IDENTITY="-"
SIGN_KEYCHAIN=""
SIGN_TIMESTAMP_ARGS=(--timestamp=none)

case "${DSH_LOCAL_SIGNING:-0}" in
  0|1) ;;
  *)
    echo "DSH_LOCAL_SIGNING must be 0 or 1." >&2
    exit 2
    ;;
esac

if [[ "${DSH_LOCAL_SIGNING:-0}" == "1" \
    && ( -n "${DSH_SIGN_IDENTITY:-}" || -n "${DSH_SIGN_KEYCHAIN:-}" ) ]]; then
  echo "DSH_LOCAL_SIGNING=1 uses its own fixed managed keychain; do not combine it with DSH_SIGN_IDENTITY or DSH_SIGN_KEYCHAIN." >&2
  exit 2
fi

if [[ "${DSH_LOCAL_SIGNING:-0}" == "1" ]]; then
  if [[ ! -x "$SIGNING_HELPER" ]]; then
    echo "Missing executable signing helper: $SIGNING_HELPER" >&2
    exit 1
  fi
  SIGNING_OUTPUT="$("$SIGNING_HELPER")"
  SIGN_IDENTITY="$(/usr/bin/printf '%s\n' "$SIGNING_OUTPUT" | /usr/bin/sed -n '1p')"
  SIGN_KEYCHAIN="$(/usr/bin/printf '%s\n' "$SIGNING_OUTPUT" | /usr/bin/sed -n '2p')"
  SIGN_MODE="local"
elif [[ -n "${DSH_SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$DSH_SIGN_IDENTITY"
  SIGN_KEYCHAIN="${DSH_SIGN_KEYCHAIN:-}"
  SIGN_MODE="identity"

  IDENTITY_DETAILS=""
  SECURITY_ARGS=(find-identity -v -p codesigning)
  if [[ -n "$SIGN_KEYCHAIN" ]]; then
    SECURITY_ARGS+=("$SIGN_KEYCHAIN")
  fi
  IDENTITY_DETAILS="$(
    /usr/bin/security "${SECURITY_ARGS[@]}" 2>/dev/null \
      | /usr/bin/grep -F "$SIGN_IDENTITY" \
      | /usr/bin/head -n 1 \
      || true
  )"
  if [[ "$SIGN_IDENTITY" == Developer\ ID\ Application:* \
      || "$IDENTITY_DETAILS" == *'"Developer ID Application:'* ]]; then
    SIGN_TIMESTAMP_ARGS=(--timestamp)
    SIGN_MODE="developer-id"
  fi
elif [[ -n "${DSH_SIGN_KEYCHAIN:-}" ]]; then
  echo "DSH_SIGN_KEYCHAIN requires DSH_SIGN_IDENTITY." >&2
  exit 2
fi

/usr/bin/printf 'Code signing mode: %s\n' "$SIGN_MODE"

cleanup() {
  /bin/rm -rf -- "$DIST_DIR"
}
trap cleanup EXIT

sign_bundle() {
  local bundle="$1"
  local codesign_args=(
    --force
    --options runtime
    "${SIGN_TIMESTAMP_ARGS[@]}"
  )
  if [[ -n "$SIGN_KEYCHAIN" ]]; then
    codesign_args+=(--keychain "$SIGN_KEYCHAIN")
  fi
  codesign_args+=(--sign "$SIGN_IDENTITY")

  /usr/bin/xattr -cr "$bundle"
  for helper in "$bundle/Contents/Helpers/"*; do
    if [[ -f "$helper" && -x "$helper" ]]; then
      /usr/bin/codesign "${codesign_args[@]}" "$helper"
    fi
  done
  /usr/bin/codesign "${codesign_args[@]}" "$bundle"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$bundle"
}

stop_running_app() {
  local shell_group
  shell_group="$(/bin/ps -o pgid= -p $$ | /usr/bin/tr -d ' ')"

  for app_pid in $(/usr/bin/pgrep -x "$APP_NAME" 2>/dev/null || true); do
    local child_records=""
    for child_pid in $(/usr/bin/pgrep -P "$app_pid" 2>/dev/null || true); do
      local child_group
      child_group="$(/bin/ps -o pgid= -p "$child_pid" | /usr/bin/tr -d ' ')"
      if [[ "$child_pid" =~ ^[0-9]+$ && "$child_group" =~ ^[0-9]+$ ]]; then
        child_records="$child_records $child_pid:$child_group"
      fi
    done

    /bin/kill -TERM "$app_pid" 2>/dev/null || true
    for _ in {1..20}; do
      /bin/kill -0 "$app_pid" 2>/dev/null || break
      /bin/sleep 0.1
    done

    for record in $child_records; do
      local child_pid="${record%%:*}"
      local child_group="${record##*:}"
      if /bin/kill -0 "$child_pid" 2>/dev/null \
          && [[ "$child_group" != "$shell_group" && "$child_group" -gt 1 ]]; then
        /bin/kill -TERM -- "-$child_group" 2>/dev/null || true
        for _ in {1..20}; do
          /bin/kill -0 "$child_pid" 2>/dev/null || break
          /bin/sleep 0.1
        done
        if /bin/kill -0 "$child_pid" 2>/dev/null; then
          /bin/kill -KILL -- "-$child_group" 2>/dev/null || true
        fi
      fi
    done
  done
}

case "$MODE" in
  package|--package) ;;
  *) stop_running_app ;;
esac

swift build --package-path "$PROJECT_DIR" -c release
BUILD_DIR="$(swift build --package-path "$PROJECT_DIR" -c release --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$PRODUCT_NAME"
BUILD_HELPER="$BUILD_DIR/DeepSeekAppBridge"
BUILD_ARTIFACT_HELPER="$BUILD_DIR/DeepSeekArtifactBridge"

mkdir -p "$APP_MACOS" "$APP_HELPERS" "$APP_RESOURCES" "$ICONSET_DIR"
cp -f "$BUILD_BINARY" "$APP_BINARY"
cp -f "$BUILD_HELPER" "$HELPER_BINARY"
cp -f "$BUILD_ARTIFACT_HELPER" "$ARTIFACT_HELPER_BINARY"
chmod +x "$APP_BINARY"
chmod +x "$HELPER_BINARY"
chmod +x "$ARTIFACT_HELPER_BINARY"

if [[ ! -d "$INTEGRATION_SOURCE" ]]; then
  echo "Missing Harness integration resources: $INTEGRATION_SOURCE" >&2
  exit 1
fi
/usr/bin/ditto --norsrc --noextattr "$INTEGRATION_SOURCE" "$INTEGRATION_RESOURCES"
if [[ ! -f "$INTEGRATION_SOURCE/model-capabilities.json" ]]; then
  echo "Missing model capability registry: $INTEGRATION_SOURCE/model-capabilities.json" >&2
  exit 1
fi
/bin/cp -f "$INTEGRATION_SOURCE/model-capabilities.json" "$APP_RESOURCES/model-capabilities.json"

if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "Missing app icon source: $ICON_SOURCE" >&2
  exit 1
fi

# Render the original companion mark into every representation expected by a
# standard macOS .icns file. Keeping the SVG in the project makes packaging
# independent of the local Harness server and its installed version.
/usr/bin/sips -s format png "$ICON_SOURCE" --out "$ICON_MASTER" >/dev/null
while read -r filename pixels; do
  /usr/bin/sips -z "$pixels" "$pixels" "$ICON_MASTER" --out "$ICONSET_DIR/$filename" >/dev/null
done <<'ICON_SIZES'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
ICON_SIZES
/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon.icns</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.5.0</string>
  <key>CFBundleVersion</key>
  <string>7</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>LSMultipleInstancesProhibited</key>
  <true/>
  <key>NSScreenCaptureUsageDescription</key>
  <string>仅在你明确附加应用并要求读取画面时，在本机内存中识别该窗口文字。</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
</dict>
</plist>
PLIST

sign_bundle "$APP_BUNDLE"
# Do not keep an unpacked .app inside Documents. FileProvider can re-add
# FinderInfo after signing and invalidate the bundle asynchronously. The
# metadata-free ZIP below is the locally verifiable workspace artifact; the only
# user-facing unpacked copy belongs in /Applications.
case "$OUTPUT_APP" in
  "$ROOT_DIR/outputs/"*.app) ;;
  *)
    echo "Refusing to replace unexpected output path: $OUTPUT_APP" >&2
    exit 2
    ;;
esac
/bin/rm -rf -- "$OUTPUT_APP"

# Documents may be backed by FileProvider, which can re-add FinderInfo to an
# otherwise valid .app after packaging and invalidate a later strict check.
# Keep a metadata-free archive as the locally verifiable reinstall artifact,
# and prove it by extracting into the private staging directory and verifying it.
case "$OUTPUT_ZIP" in
  "$ROOT_DIR/outputs/"*.zip) ;;
  *)
    echo "Refusing to replace unexpected archive path: $OUTPUT_ZIP" >&2
    exit 2
    ;;
esac
/bin/rm -f -- "$OUTPUT_ZIP"
/usr/bin/ditto -c -k --keepParent --norsrc --noextattr "$APP_BUNDLE" "$OUTPUT_ZIP"
ZIP_VERIFY_DIR="$DIST_DIR/zip-verify"
/bin/mkdir -p "$ZIP_VERIFY_DIR"
/usr/bin/ditto -x -k "$OUTPUT_ZIP" "$ZIP_VERIFY_DIR"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$ZIP_VERIFY_DIR/$APP_NAME.app"
/usr/bin/shasum -a 256 "$OUTPUT_ZIP"

open_app() {
  local installed_app=""
  if [[ -d "$SYSTEM_INSTALLED_APP" ]]; then
    installed_app="$SYSTEM_INSTALLED_APP"
  elif [[ -d "$USER_INSTALLED_APP" ]]; then
    installed_app="$USER_INSTALLED_APP"
  else
    echo "No installed app at $SYSTEM_INSTALLED_APP or $USER_INSTALLED_APP; package and install the verified ZIP first." >&2
    exit 1
  fi
  /usr/bin/open -n "$installed_app"
}

case "$MODE" in
  package|--package)
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == '$APP_NAME'"
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == '$BUNDLE_ID'"
    ;;
  --verify|verify)
    open_app
    for _ in {1..20}; do
      if pgrep -x "$APP_NAME" >/dev/null; then
        exit 0
      fi
      sleep 0.25
    done
    echo "$APP_NAME did not launch" >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [package|run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
