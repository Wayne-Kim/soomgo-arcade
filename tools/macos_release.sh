#!/usr/bin/env bash
# Build a notarized, Sparkle-updatable macOS release of Soomgo Arcade and refresh the appcast.
#
# Pipeline: Godot export -> embed Sparkle.framework -> code-sign (XPC services -> Autoupdate ->
# framework -> app, never `--deep`) -> notarize + staple -> zip -> EdDSA-sign with Sparkle ->
# regenerate the appcast. Sparkle is for DIRECT distribution only (never the Mac App Store).
#
# Required environment:
#   GODOT                 path to the Godot 4.x editor binary (for --export-release)
#   EXPORT_PRESET         macOS export preset name in export_presets.cfg (e.g. "macOS")
#   SIGN_IDENTITY         "Developer ID Application: Your Name (TEAMID)"
#   SPARKLE_BIN           dir with Sparkle's CLI tools (sign_update, generate_appcast) + framework
#   SPARKLE_PRIVATE_KEY   path to the EdDSA private key file (from Sparkle's generate_keys -x)
#   UPDATES_DIR           local folder holding past update archives + appcast.xml (your feed root)
# Notarization credential (one of):
#   secrets/asc-api-key.env  App Store Connect API key (preferred, gitignored) — sourced if present
#   NOTARY_PROFILE           `xcrun notarytool store-credentials` profile name (fallback)
# Optional:
#   APP_NAME              defaults to "Soomgo Arcade"
#   ENTITLEMENTS          hardened-runtime entitlements plist (defaults to tools/sparkle/entitlements.plist)
set -euo pipefail

APP_NAME="${APP_NAME:-Soomgo Arcade}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/macos"
APP="$OUT/$APP_NAME.app"
ENTITLEMENTS="${ENTITLEMENTS:-$ROOT/tools/sparkle/entitlements.plist}"

for v in GODOT EXPORT_PRESET SIGN_IDENTITY SPARKLE_BIN SPARKLE_PRIVATE_KEY UPDATES_DIR; do
	if [ -z "${!v:-}" ]; then echo "error: \$$v is required" >&2; exit 1; fi
done

# Notarization credential — prefer the file-based ASC API key (secrets/asc-api-key.env,
# gitignored); fall back to a keychain notarytool profile ($NOTARY_PROFILE).
if [ -f "$ROOT/secrets/asc-api-key.env" ]; then
	# shellcheck disable=SC1091
	source "$ROOT/secrets/asc-api-key.env"
fi
ASC_READY=1
for v in ASC_API_KEY_ID ASC_API_ISSUER_ID ASC_API_KEY_PATH; do [ -n "${!v:-}" ] || ASC_READY=0; done
if [ "$ASC_READY" -eq 0 ] && [ -z "${NOTARY_PROFILE:-}" ]; then
	echo "error: provide secrets/asc-api-key.env (ASC API key) or set \$NOTARY_PROFILE" >&2; exit 1
fi

echo ">> Exporting $APP_NAME via Godot preset '$EXPORT_PRESET'"
rm -rf "$OUT"; mkdir -p "$OUT"
"$GODOT" --headless --path "$ROOT" --export-release "$EXPORT_PRESET" "$APP"

echo ">> Embedding Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE_BIN/Sparkle.framework" "$APP/Contents/Frameworks/"

# --- Code signing. Order matters; deep-sign helper tools first, then the app, NEVER `--deep`. ---
FW="$APP/Contents/Frameworks/Sparkle.framework"
sign() { codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@"; }

echo ">> Signing Sparkle helper tools + framework"
sign "$FW/Versions/B/XPCServices/Installer.xpc" || true
sign "$FW/Versions/B/XPCServices/Downloader.xpc" || true
sign "$FW/Versions/B/Autoupdate" || true
sign "$FW/Versions/B/Updater.app" || true
sign "$FW"

echo ">> Signing the app (hardened runtime, with entitlements)"
sign --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# --- Notarize + staple ---
ZIP="$OUT/$APP_NAME.zip"
echo ">> Notarizing"
ditto -c -k --keepParent "$APP" "$ZIP"
if [ "$ASC_READY" -eq 1 ]; then
	xcrun notarytool submit "$ZIP" --key "$ASC_API_KEY_PATH" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID" --wait
else
	xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
fi
xcrun stapler staple "$APP"

# --- Repackage the stapled app + EdDSA-sign + appcast ---
echo ">> Building the update archive"
mkdir -p "$UPDATES_DIR"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$UPDATES_DIR/$APP_NAME.zip"

echo ">> EdDSA signature (informational; generate_appcast also signs)"
"$SPARKLE_BIN/sign_update" "$UPDATES_DIR/$APP_NAME.zip" -f "$SPARKLE_PRIVATE_KEY"

echo ">> Regenerating appcast.xml"
"$SPARKLE_BIN/generate_appcast" --ed-key-file "$SPARKLE_PRIVATE_KEY" "$UPDATES_DIR"

echo ">> Done. Publish the contents of $UPDATES_DIR (the .zip + appcast.xml) to your SUFeedURL host over HTTPS."
