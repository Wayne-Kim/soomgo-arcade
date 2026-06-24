#!/usr/bin/env bash
# One-command macOS release for Soomgo Arcade: export -> sign -> notarize -> staple -> package.
# Implements docs/DEPLOY_MACOS.md §4-5 (the non-Sparkle distribution flow). The Sparkle/appcast
# auto-update flow lives in tools/macos_release.sh (see docs/UPDATES.md) and uses the same key.
#
# Notarization credential: an App Store Connect API key (.p8). Single source of truth is
# secrets/asc-api-key.env (gitignored) which exports ASC_API_KEY_ID / ASC_API_ISSUER_ID /
# ASC_API_KEY_PATH. The key is team-wide, so it notarizes any app under the team — no per-app
# App Store record needed. The signing identity (and its team) is auto-detected from the keychain;
# no identifiers are hardcoded here so this file is safe to publish.
#
# Usage:
#   ./tools/deploy_macos.sh            # build + sign + notarize + staple -> build/macos/<app>.zip
#   ./tools/deploy_macos.sh --dmg      # also produce a notarized .dmg
#
# Overridable env: GODOT, EXPORT_PRESET, APP_NAME, SIGN_IDENTITY, ENTITLEMENTS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-Soomgo Arcade}"
EXPORT_PRESET="${EXPORT_PRESET:-macOS}"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
ENTITLEMENTS="${ENTITLEMENTS:-$ROOT/tools/sparkle/entitlements.plist}"
OUT="$ROOT/build/macos"
APP="$OUT/$APP_NAME.app"
MAKE_DMG=0
[ "${1:-}" = "--dmg" ] && MAKE_DMG=1

red()   { printf "\033[31m%s\033[0m\n" "$*" >&2; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
step()  { printf "\n\033[1;36m▸ %s\033[0m\n" "$*"; }

# ----------------------------------------------------------------------------
# 0) preflight
# ----------------------------------------------------------------------------
step "환경 점검"
[ -x "$GODOT" ] || { red "Godot 실행 파일 없음: $GODOT  (GODOT=/path/to/Godot 로 지정)"; exit 1; }
[ -f "$ENTITLEMENTS" ] || { red "entitlements 없음: $ENTITLEMENTS"; exit 1; }

# export_presets.cfg 는 codesign/apple_team_id(Apple 식별자) 때문에 gitignored. 추적되는 건
# team_id 를 비운 export_presets.cfg.example 뿐 — 실제 파일이 없으면 거기서 부트스트랩한다.
# (codesign/codesign=0 이라 빈 team_id 로도 export 는 정상; 서명은 이 스크립트가 한다.)
if [ ! -f "$ROOT/export_presets.cfg" ] && [ -f "$ROOT/export_presets.cfg.example" ]; then
	cp "$ROOT/export_presets.cfg.example" "$ROOT/export_presets.cfg"
	green "export_presets.cfg 부트스트랩 (from .example)"
fi
[ -f "$ROOT/export_presets.cfg" ] || { red "export_presets.cfg 없음 (그리고 .example 도 없음)"; exit 1; }

# 공증 자격증명 — secrets/asc-api-key.env 가 single source of truth (gitignored).
if [ -f "$ROOT/secrets/asc-api-key.env" ]; then
	# shellcheck disable=SC1091
	source "$ROOT/secrets/asc-api-key.env"
fi
for v in ASC_API_KEY_ID ASC_API_ISSUER_ID ASC_API_KEY_PATH; do
	[ -n "${!v:-}" ] || { red "공증 자격증명 누락: \$$v — secrets/asc-api-key.env 확인 (docs/DEPLOY_MACOS.md §2)"; exit 1; }
done
[ -f "$ASC_API_KEY_PATH" ] || { red "ASC API 키 파일 없음: $ASC_API_KEY_PATH"; exit 1; }

# 사인 ID — keychain 의 'Developer ID Application' 인증서 자동 탐색.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
	SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
		| grep "Developer ID Application:" | head -1 | sed -E 's/^[^"]*"([^"]+)".*/\1/')"
fi
[ -n "$SIGN_IDENTITY" ] || { red "Developer ID Application 인증서를 keychain 에서 못 찾음 (security find-identity -v -p codesigning)"; exit 1; }

# 버전 — export preset 의 short_version.
VERSION="$(awk -F'"' '/^application\/short_version=/{print $2; exit}' "$ROOT/export_presets.cfg")"
VERSION="${VERSION:-0.0.0}"
ZIP="$OUT/Soomgo-Arcade-${VERSION}.zip"

green "사인 ID : $SIGN_IDENTITY"
green "공증 키 : $ASC_API_KEY_ID (issuer ${ASC_API_ISSUER_ID})"
green "버전    : $VERSION"

# ----------------------------------------------------------------------------
# 1) export
# ----------------------------------------------------------------------------
step "Godot export (preset '$EXPORT_PRESET')"
rm -rf "$OUT"; mkdir -p "$OUT"
"$GODOT" --headless --path "$ROOT" --export-release "$EXPORT_PRESET" "$APP"
[ -d "$APP" ] || { red "export 산출물 없음: $APP"; exit 1; }

# ----------------------------------------------------------------------------
# 2) sign (Developer ID + hardened runtime)
# ----------------------------------------------------------------------------
step "코드 사인"
codesign --force --options runtime --timestamp \
	--entitlements "$ENTITLEMENTS" \
	--sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# ----------------------------------------------------------------------------
# 3) notarize (notarytool, ASC API key)
# ----------------------------------------------------------------------------
step "공증 (notarize)"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" \
	--key "$ASC_API_KEY_PATH" \
	--key-id "$ASC_API_KEY_ID" \
	--issuer "$ASC_API_ISSUER_ID" \
	--wait --timeout 30m

# ----------------------------------------------------------------------------
# 4) staple + repackage (티켓을 번들에 부착한 뒤 다시 zip)
# ----------------------------------------------------------------------------
step "staple + 재패키징"
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# ----------------------------------------------------------------------------
# 5) verify
# ----------------------------------------------------------------------------
step "검증"
xcrun stapler validate "$APP"
spctl -a -vvv -t exec "$APP" || true   # "source=Notarized Developer ID" 면 OK

# ----------------------------------------------------------------------------
# 6) optional DMG
# ----------------------------------------------------------------------------
if [ "$MAKE_DMG" -eq 1 ]; then
	step "DMG 포장 + 공증"
	DMG="$OUT/Soomgo-Arcade-${VERSION}.dmg"
	hdiutil create -volname "Soomgo Arcade" -srcfolder "$APP" -ov -format UDZO "$DMG"
	codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
	xcrun notarytool submit "$DMG" \
		--key "$ASC_API_KEY_PATH" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID" \
		--wait --timeout 30m
	xcrun stapler staple "$DMG"
	xcrun stapler validate "$DMG"
	green "DMG: $DMG"
fi

green ""
green "✔ 배포 산출물 준비 완료"
green "  ZIP: $ZIP"
# if-block (not `[ … ] && …`): a bare test as the script's last line would make a
# DMG-less run exit 1 under `set -e` even though everything succeeded.
if [ "$MAKE_DMG" -eq 1 ]; then green "  DMG: $OUT/Soomgo-Arcade-${VERSION}.dmg"; fi
