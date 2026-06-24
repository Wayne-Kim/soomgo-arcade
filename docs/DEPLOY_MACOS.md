# macOS 배포 가이드 (Soomgo Arcade)

Godot 4.6 macOS 앱을 **빌드 → 서명 → 공증(notarize) → 배포**하는 절차입니다.
공증 자격증명은 **App Store Connect API 키**(파일 기반)를 쓰며, 한 줄 스크립트
`./tools/deploy_macos.sh` 로 전 과정을 자동화합니다.

> 🔐 **이 repo 는 곧 public 으로 전환됩니다.** 모든 비밀(공증 키 `.p8`, `asc-api-key.env`,
> Sparkle 개인키)은 **`secrets/` 디렉터리**에 두며, `secrets/` 는 `.gitignore` 로 제외되어
> **git 에 절대 포함되지 않습니다.** 커밋 전 `git status` 에 `secrets/` 가 안 보이는지 항상 확인하세요.

---

## 0. 지금 상태

| 항목 | 상태 |
|---|---|
| macOS export 템플릿 (4.6.2.stable) | ✅ 설치됨 |
| export 프리셋 (`export_presets.cfg`) | ✅ 구성됨 (universal, `com.soomgo.arcade`, v1.0.0) |
| Developer ID Application 인증서 | ✅ keychain 에 존재 (스크립트가 자동 탐색) |
| 공증 자격증명 (ASC API 키) | ✅ `secrets/` 에 세팅됨 (gitignored) |
| **릴리스 스크립트** | ✅ `./tools/deploy_macos.sh` (export·서명·공증·staple·패키징 자동화) |
| 자동 업데이트(Sparkle) | ⛔ 선택 — `docs/UPDATES.md` 참고 (`tools/macos_release.sh`, 같은 키 사용) |

> 공증을 안 하면 상대 Mac 에서 "Apple이 악성 여부를 확인할 수 없어 열 수 없습니다" 로 차단됩니다.
> 아래 스크립트가 공증 + staple 까지 처리하므로 다른 Mac 에 그대로 배포할 수 있습니다.

---

## 1. 사전 준비물 (1회)

- Apple **Developer Program** 가입 (연 $99)
- **Developer ID Application** 인증서 → ✅ keychain 에 보유 (이름·Team ID 는 비공개이며,
  릴리스 스크립트가 `security find-identity` 로 자동 탐색 — 문서/코드에 박지 않음)
- Xcode Command Line Tools (`xcode-select --install`)
- 공증 자격증명(ASC API 키) → ✅ `secrets/` 에 세팅됨 (아래 2)

---

## 2. 공증 자격증명 — App Store Connect API 키 (파일 기반)

공증은 **팀 단위**라 앱별 App Store 레코드가 필요 없습니다. 그래서 같은 팀의
다른 프로젝트에서 쓰던 ASC API 키(`.p8`)를 그대로 재사용합니다. 키는 keychain 이 아니라
**`secrets/` 안의 파일**로 두므로 별도 로그인/프로필 저장 단계가 없습니다.

`secrets/` 구성:

```
secrets/
├─ AuthKey-<KEY_ID>.p8     # ASC API 개인키 (.p8) — 절대 커밋 금지
└─ asc-api-key.env         # 키 식별자/경로를 export
```

`secrets/asc-api-key.env` 형식 (실제 값은 이 gitignored 파일 안에만 존재):

```sh
export ASC_API_KEY_ID="<KEY_ID>"
export ASC_API_ISSUER_ID="<ISSUER_ID>"
export ASC_API_KEY_PATH="$ROOT/secrets/AuthKey-<KEY_ID>.p8"
```

> 💡 새 기기/CI 에서 세팅하려면 위 두 파일을 안전한 경로에서 `secrets/` 로 복사하면 됩니다.
> `$ROOT` 는 배포 스크립트가 `source` 하기 전에 repo 루트로 미리 정의합니다.
>
> 키가 없거나 새로 만들려면 App Store Connect → **Users and Access → Integrations →
> App Store Connect API** 에서 키 생성(역할: *Developer* 이상). `.p8` 는 **한 번만**
> 내려받을 수 있으니 바로 `secrets/` 에 보관하세요.

---

## 3. 릴리스 (한 줄)

새 버전을 낼 때마다 **버전 번호를 올리고**(`export_presets.cfg` 의 `application/short_version`,
`application/version`) 스크립트를 실행합니다. `application/version`(= CFBundleVersion)은
**매번 1씩 증가**해야 합니다(Sparkle/업데이트 판정 기준).

```sh
./tools/deploy_macos.sh          # zip 산출물
./tools/deploy_macos.sh --dmg    # zip + 공증된 .dmg
```

스크립트가 하는 일 (전부 자동):

1. **자동 탐색** — keychain 에서 `Developer ID Application` 인증서, 기본 경로의 Godot,
   `export_presets.cfg` 의 버전, `secrets/asc-api-key.env` 의 공증 키.
2. **export** — `build/macos/Soomgo Arcade.app`
3. **서명** — Developer ID + Hardened Runtime + `tools/sparkle/entitlements.plist`
4. **공증** — `notarytool submit --wait` (ASC API 키)
5. **staple + 재패키징** — 티켓 부착 후 `build/macos/Soomgo-Arcade-<버전>.zip`
6. **검증** — `stapler validate` + `spctl`

오버라이드 환경변수(선택): `GODOT`, `EXPORT_PRESET`, `APP_NAME`, `SIGN_IDENTITY`, `ENTITLEMENTS`.

---

## 4. 수동 절차 (스크립트가 막힐 때 참고)

스크립트 각 단계는 아래와 동일합니다. 디버깅 시 한 단계씩 실행하세요.

```sh
GODOT=/Applications/Godot.app/Contents/MacOS/Godot
ROOT="$(pwd)"; source secrets/asc-api-key.env   # ROOT 먼저 → ASC_API_* 로딩

# 4-0. export_presets.cfg 는 gitignored (Team ID 포함) — 없으면 template 에서 부트스트랩
[ -f export_presets.cfg ] || cp export_presets.cfg.example export_presets.cfg

# 4-1. export
rm -rf build/macos && mkdir -p build/macos
"$GODOT" --headless --path . --export-release "macOS" "build/macos/Soomgo Arcade.app"

# 4-2. 서명 (Developer ID + Hardened Runtime)
# 서명 ID 는 keychain 에서 자동 탐색 (이름·Team ID 를 문서에 박지 않기 위함)
SIGN_IDENTITY="$(security find-identity -v -p codesigning | grep 'Developer ID Application:' | head -1 | sed -E 's/^[^"]*"([^"]+)".*/\1/')"
codesign --force --options runtime --timestamp \
  --entitlements tools/sparkle/entitlements.plist \
  --sign "$SIGN_IDENTITY" \
  "build/macos/Soomgo Arcade.app"
codesign --verify --deep --strict --verbose=2 "build/macos/Soomgo Arcade.app"

# 4-3. 공증 (ASC API 키)
ditto -c -k --keepParent "build/macos/Soomgo Arcade.app" "build/macos/Soomgo-Arcade-1.0.0.zip"
xcrun notarytool submit "build/macos/Soomgo-Arcade-1.0.0.zip" \
  --key "$ASC_API_KEY_PATH" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID" --wait
# status: Accepted 면 성공. Invalid 면: xcrun notarytool log <submission-id> --key ... --key-id ... --issuer ...

# 4-4. staple + 재패키징
xcrun stapler staple "build/macos/Soomgo Arcade.app"
rm -f "build/macos/Soomgo-Arcade-1.0.0.zip"
ditto -c -k --keepParent "build/macos/Soomgo Arcade.app" "build/macos/Soomgo-Arcade-1.0.0.zip"

# 4-5. 검증
xcrun stapler validate "build/macos/Soomgo Arcade.app"
spctl -a -vvv -t exec "build/macos/Soomgo Arcade.app"   # "source=Notarized Developer ID" 면 OK
```

---

## 5. 배포

- 가장 간단: **`build/macos/Soomgo-Arcade-<버전>.zip`** 을 다운로드 링크로 제공
- 더 깔끔하게: `./tools/deploy_macos.sh --dmg` 로 공증된 `.dmg` 까지 생성

---

## 6. 자동 업데이트 (Sparkle) — 선택

앱이 스스로 새 버전을 받도록 하려면 Sparkle 을 추가합니다. 전체 절차는
**[`docs/UPDATES.md`](UPDATES.md)** 참고. 릴리스 파이프라인은 `tools/macos_release.sh` 이며,
**공증은 위와 같은 `secrets/asc-api-key.env` 키를 그대로 사용**합니다 (없으면 `NOTARY_PROFILE` 폴백).

---

## 7. 자주 나는 오류

| 증상 | 원인 / 해결 |
|---|---|
| `공증 자격증명 누락: $ASC_API_KEY_ID` | `secrets/asc-api-key.env` 없음/미설정 — 2단계 확인 |
| `ASC API 키 파일 없음` | `.p8` 가 `secrets/` 에 없음 — 다른 기기에서 복사 |
| 공증 `Invalid` | `xcrun notarytool log <submission-id> --key … --key-id … --issuer …` 로 원인 확인 |
| `notarytool` 401 / 권한 오류 | ASC API 키 역할이 *Developer* 미만 — App Store Connect 에서 역할 상향 |
| 상대 Mac 에서 "열 수 없습니다" | 공증/스테이플 누락 — 4-3, 4-4 수행 (스크립트는 자동) |
| "You're up to date"인데 새 버전 있음 (Sparkle) | `application/version`(CFBundleVersion) 미증가 |
| export 시 ETC2/ASTC 오류 | `project.godot` 의 `rendering/textures/vram_compression/import_etc2_astc=true` (설정됨) |
| 서명 시 인증서 못 찾음 | `security find-identity -v -p codesigning` 로 Developer ID 존재 확인 |

---

## 부록: 이 프로젝트의 고정값

> ⚠️ Team ID·서명자 실명 등 **신원 식별 정보는 문서/코드에 박지 않습니다.** keychain
> 인증서(`security find-identity -v -p codesigning`)에서 런타임에 자동 탐색하며, 공증 키
> 식별자는 `secrets/`(gitignored) 안에만 존재합니다.

| 항목 | 값 |
|---|---|
| Team ID / 서명 ID | keychain 의 `Developer ID Application` 에서 자동 탐색 (비공개) |
| Bundle ID | `com.soomgo.arcade` |
| 공증 키 | `secrets/asc-api-key.env` (ASC API 키, gitignored) |
| export 프리셋 이름 | `macOS` (`export_presets.cfg` gitignored, `*.example` 만 추적) |
| entitlements | `tools/sparkle/entitlements.plist` |
| 릴리스 스크립트 | `tools/deploy_macos.sh` (Sparkle 은 `tools/macos_release.sh`) |
| 산출물 경로 | `build/macos/` |
</content>
</invoke>
