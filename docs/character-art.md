# 숨고 고수 캐릭터 스프라이트 — 아트 제작 명세서

이미 구현된 프로젝트의 코드를 손상시키지 않고 5개의 캐릭터 스프라이트를 제작/생성하는 가이드라인입니다. 캐릭터 정보 문서([`docs/characters.md`](characters.md)) 및 브랜드 가이드([`docs/BRAND.md`](BRAND.md))와 긴밀히 연계되어 있으며, 본 문서는 리소스 제작 관점의 **아트 프로덕션 레시피**를 제공합니다.

**범위:** 디자인 / 아트 제작 문서 및 에셋 시트 규격에 **한정**됩니다. 엔진 코드는 변경하지 않습니다. 제작된 에셋 시트를 `Game.gd` 렌더러에 연동하는 작업은 추후 별도 과제로 진행되며 본 문서의 범위에서 제외됩니다. 통합 작업이 진행되기 전까지 보드는 기존의 `TeamMarker` 도형을 계속 렌더링하며, 본 명세는 통합 후에도 아래의 약속을 온전히 지킬 수 있도록 에셋이 충족해야 하는 규칙을 정의합니다.

> **통합 현황 (파일럿 적용 완료):** 본 명세에서 정의한 렌더러 연동 기능이 **이사의 'Tote(짐꾼이)'** 캐릭터를 파일럿으로 하여 구현되었습니다: `scripts/ui/CharacterSprites.gd`가 `<id>_base.png` + `<id>_mask.png` 시트를 로드하고, 런타임에 마스크 영역을 `Game.TEAM_COLORS` 색상으로 칠합니다. `Game.gd._draw()`는 대기(idle)/이동(walk)/갇힘(trapped) 애니메이션을 처리하고, 중복 표시를 피하기 위해 기존 `TeamMarker` 도형을 **구석의 발판 배지 영역**으로 이동시켰습니다. 아트가 아직 제작되지 않은 캐릭터는 기존의 도형 마커를 사용해 렌더링합니다. 파일럿 캐릭터 시트는 `tools/gen_character_sprites.gd` 스크립트를 통해 결정론적으로 작성되었습니다. 나머지 4개 캐릭터에 대한 에셋 생성은 열린 과제로 남아있으며, 에셋을 `assets/characters/<id>_{base,mask}.png` 및 `<id>.json` 경로에 추가하면 코드 수정 없이 렌더링됩니다.

다음 두 가지 핵심 결과물을 제공합니다:
- **(A)** 캐릭터별 실루엣 및 소품 상세 메모를 기반으로 한 프롬프트 템플릿
- **(B)** 7가지 승인 기준을 준수하는 에셋 시트 규격

---

## 0. 본 명세가 준수하는 디자인 SSOT (가이드라인)

에셋을 생성하는 세션 에이전트가 저장소 내 다른 디자인 문서를 직접 읽지 못할 수 있으므로, 제약이 되는 주요 규칙들을 단일 진실 공급원(SSOT) 링크와 함께 아래에 정리합니다. **이 규칙들을 준수하며 새로운 규칙을 임의로 만들지 마십시오.**

| 규칙 | 단일 진실 공급원 (SSOT) | 아트에 적용되는 제약 사항 |
| --- | --- | --- |
| **의미에 따른 색상 구분**<br>보드상의 색상은 팀/플레이어 구분을 위해서만 사용되며 런타임에 결정됩니다. "최종 색상 = 팀 색상"이며, 픽셀 자체에 캐릭터 전용 색상을 칠하지 마십시오. | `scripts/ui/Game.gd:81-84` (`TEAM_COLORS`, 기능적 아레나 렌더링용이며 브랜드 팔레트가 아님); `docs/characters.md`; `docs/BRAND.md` | 스프라이트는 **뉴트럴 그레이스케일(무채색)**로 제작하고 **별도의 팀 색상 마스크**를 제공해야 합니다. 팀 색상은 런타임에 칠해집니다. (기준 1) |
| **색상이 유일한 단서가 아님**<br>팀을 식별할 수 있는 고유한 도형이 모든 마커에 겹쳐서 표시되며, 갇힘 및 무적 상태에서도 유지됩니다. | `scripts/ui/TeamMarker.gd` (8개 도형, `SHAPE_COUNT`), `Game.gd` 및 HUD/점수판에 사용됨 | 스프라이트는 **캐릭터**(실루엣/소품)의 정체성을 나타내고, `TeamMarker` 도형 배지는 **팀**의 정체성을 나타냅니다. 스프라이트가 유일한 팀 식별 수단이 되지 않아야 합니다. (기준 1 & 5) |
| **보드 셀 크기 `CELL = 44 px`** | `scripts/ui/Game.gd` | 원본 에셋 프레임은 44 px 크기의 셀에 깨끗하게 다운스케일되어야 합니다. (기준 3) |
| **최대 팀 개수 8개** | `scripts/core/Spec.gd` (`MAX_PLAYERS = 8`), `TeamMarker.SHAPE_COUNT = 8` | 팀 색상 마스크는 하나의 색상이 아닌 아래의 8가지 팀 색상 전체에서 명확히 인식 가능해야 합니다. |
| **지원 로케일 세트 = {`en`, `ko`}** | `localization/ui_strings.csv` 헤더 `keys,en,ko`, `project.godot` (`locale/fallback="en"`) | 아트 리소스 내부에는 텍스트를 포함하지 않으므로 다국어 처리가 필요 없습니다. 프롬프트 생성 시 텍스트나 글자, 숫자를 배제하도록 설정합니다. (§10) |

### 기능적 팀 색상 팔레트 (마스크 QA 전용 — 스프라이트에 직접 칠하지 마십시오)

런타임에 마스크에 적용할 8가지 팀 색상 값입니다 (`Game.gd:81-84`). 마스크 검증(QA) 시 **모든** 색상에서 잘 보이는지 확인하되, 실제 저장 및 배포하는 픽셀은 항상 무채색 그레이스케일이어야 합니다:

```
#e5484d  #30a46c  #3b82f6  #f5a623  #a855f7  #06b6b6  #ec4899  #eab308
 (빨강)   (초록)   (파랑)   (황색)   (보라)   (청록)   (분홍)   (노랑)
```

### 렌더러가 실제로 그리는 상태 (기준 4)

`Game.gd._draw()` (플레이어 드로잉 블록 참고)를 기준으로 합니다. 에셋 시트는 **정확히** 아래의 상태들만 커버하며, 렌더러가 처리하지 않는 추가 상태는 작성하지 않습니다:

| 상태 | 엔진 내 처리 방식 | 시트 작성 여부 |
| --- | --- | --- |
| **대기 (idle)** | 셀 중앙에 플레이어별 1개의 마커를 드로우 (`TeamMarker.draw_shape`) + 플레이어 번호 표시 | **포함** — `idle` 행에 위치합니다. |
| **이동 (walk)** | **현재 미적용** — 현재 렌더러는 플레이어마다 1개의 정적 마커만 그립니다. 이동 프레임은 본 명세에서 **새롭게 추가**하는 요소입니다. | **포함** — `walk` 행에 위치합니다 (신규). |
| **물풍선에 갇힘 (trapped)** | `p.trapped` 조건 발생 시 하늘색(cyan) 링 모양 아크를 그림 `draw_arc(pos, CELL*0.46, …)`. *둥둥 떠다니는 물풍선* 이미지는 **별도 엔티티**이며 캐릭터 스프라이트가 아닙니다 — 스프라이트 내부에 물풍선을 그리지 마십시오. | **포함** — `trapped` 행에 캐릭터 본체만 그립니다. 엔진이 캐릭터 바깥에 물풍선 링을 직접 렌더링합니다. |
| **무적 깜빡임 (invuln blink)** (방금 구출된 상태) | 구출 직후 `Spec.RESCUE_INVULN_TICKS` 동안 활성화된 마커의 알파 채널을 `col.a = 0.55`로 감쇠하여 그림. | **시트 제외 / 런타임 계산** — 렌더러가 활성화된 `idle`/`walk` 프레임에 알파 감쇠를 직접 적용하므로, 무적 애니메이션 행을 따로 만들지 않고 55% 불투명도에서도 가독성이 유지되도록 리소스를 설계합니다 (§4, §8). |

---

## (A) 캐릭터별 프롬프트 템플릿

5개의 캐릭터 모두 동일한 **스타일 앵커**와 **네거티브 블록**을 공유합니다. 각 캐릭터는 **실루엣 + 소품 구성**이 다르며, 프레임별로 **포즈 수정자**를 뒤에 덧붙여 생성합니다. 이를 통해 전체 라인업의 통일성을 유지하면서(기준 6) 캐릭터별 실루엣은 직관적으로 구별되도록 합니다(기준 5).

### A.1 공통 스타일 앵커 (모든 프롬프트의 시작 부분에 추가)

```
flat-shaded chibi occupational mascot, single full-body character, centered, three-quarter
front view, bold instantly-readable silhouette, thick clean dark outline, simple two-tone cel
shading, one soft key light from the upper-left, NEUTRAL GRAYSCALE ONLY — no hue, no
saturation, monochrome, isolated single subject on a flat solid {WHITE|BLACK} backdrop, no
cast shadow, no ground plane, no background scenery, no text, no letters, no numbers, no logos,
game character sprite, matches the locked reference model sheet, friendly and approachable
```

`{WHITE|BLACK}` 부분은 §B.3의 **듀얼 매트(Dual-matte)** 규칙에 따라 동일한 시드값으로 배경을 흰색(`#ffffff`)과 검은색(`#000000`)으로 나누어 한 번씩 렌더링할 때 채워 넣습니다.

### A.2 공통 네거티브 블록

```
colour, color, saturated, hue, tint, gradient, team colours, red, green, blue, background,
scenery, props in background, drop shadow, floor, reflection, text, watermark, signature,
letters, numbers, UI elements, speech bubble, multiple characters, crowd, extra limbs, blurry,
low contrast, photorealistic, realistic photo, cluttered, busy pattern, noisy detail
```

> ⚠️ **프롬프트에 `transparent` (투명한) 단어를 절대 넣지 마십시오.** 많은 AI 모델들이 이 단어를 보면 투명 체크 패턴(바둑판 배경)이나 유리 재질의 물체를 그려버립니다. 투명 배경은 §B.3에 따라 후처리로 복원해야 합니다.

### A.3 캐릭터별 세부 프롬프트 변수 (실루엣/소품 메모 기준, `docs/characters.md` 참고)

| ID (`Characters.gd`) | 캐릭터명 | 실루엣 및 소품 정보 (스타일 앵커 뒤에 덧붙임) |
| --- | --- | --- |
| `cleaning` | **Sudsy (쓱싹이)** | `SLIM, lithe, agile build — narrow shoulders, long light limbs, the leanest of the set; holding a small SPRAY BOTTLE in one hand with a folded CLEANING CLOTH tucked at the hip; light short apron; light quick poised stance, up on the toes` |
| `moving` | **Tote (짐꾼이)** | `BULKY, broad, heavy build — wide square shoulders, stout and stocky; a stack of CARDBOARD BOXES strapped to the back and both hands gripping a HAND-TRUCK / dolly; work gloves and a belt; planted sturdy low stance` |
| `interior` | **Rolly (롤러)** | `TALL, broad-shouldered build — the TALLEST of the set, long torso; a long PAINT-ROLLER on a pole resting over one shoulder; bib overalls and a folded painter's cap; commanding upright stance` |
| `lesson` | **Menty (멘티)** | `UPRIGHT, neat, trim build — tidy balanced posture, average proportions (the set's baseline); a WHISTLE on a lanyard around the neck and a short POINTER stick in one hand; tucked-in coach polo; even centered stance` |
| `pet` | **Paws (발바닥)** | `SMALL, rounded, compact build — the SHORTEST of the set, soft round outline; a coiled LEASH in one hand and a PAW-PRINT patch on the chest; rounded ears on a soft cap; nimble crouched-ready stance` |

**기준 캐릭터:** **`lesson` / Menty (멘티)의 `idle` 0번 프레임을 먼저 생성**합니다. 단정하고 평균적인 체형 비율을 가지고 있어 전체 캐릭터의 표준적인 척도가 됩니다. 이를 시각적으로 승인한 뒤, 다른 캐릭터와 프레임 생성 시 이 결과물을 기준 조건(img2img / Reference-only / IP-Adapter 등)으로 삼아 일관성을 맞춥니다 (§B.6).

### A.4 포즈 수정자 (캐릭터 세부 내용 뒤에 부착, 프레임별로 1개씩 적용)

| 행 · 프레임 | 포즈 수정 내용 |
| --- | --- |
| `idle` · 0 | `relaxed idle, weight settled, arms at sides holding the prop, facing forward` |
| `idle` · 1 | `same relaxed idle pose, very subtle breathing bob (shoulders raised ~2px), otherwise identical` |
| `walk` · 0 | `walk cycle — left-foot contact step, slight forward lean, prop held, mid-stride` |
| `walk` · 1 | `walk cycle — passing position, legs together, body lifted, prop held` |
| `walk` · 2 | `walk cycle — right-foot contact step, slight forward lean, prop held, mid-stride` |
| `walk` · 3 | `walk cycle — passing position, legs together, body lifted, prop held` |
| `trapped` · 0 | `curled up small, knees tucked, hugging the prop, floating as if gently suspended; do NOT draw any bubble, ball or sphere around the character` |
| `trapped` · 1 | `same curled floating pose, gentle bob (rotated ~5°), otherwise identical; no bubble drawn` |

> 물풍선 모양의 링은 엔진(`Game.gd`)이 직접 그립니다. **갇힘(trapped) 프레임에는 캐릭터 본체만 그려야** 링이 겹쳐서 어색하게 표현되는 현상을 막을 수 있습니다.

---

## (B) 에셋 시트 규격 및 승인 기준

### B.1 시트 기하 구조 (Geometry)

- **원본 프레임 크기:** 셀당 **80 × 80 px** (기획서상의 64~88 px 범주를 만족하며, 44 px 보드 셀에 정확히 2:1로 정수 스케일 다운됩니다).
- **여백(Padding):** 각 프레임은 사방으로 **1 px 이상의 완전 투명 영역(guard border)**을 가집니다. 캐릭터 그림 본체는 약 72~76 px 높이로 채워지고 **하단 중앙에 정렬(anchored bottom-center)**되어야 44 px 셀에 맞춰 스케일 다운되었을 때 2 px 여백 테두리 바깥으로 삐져나가지 않습니다. (기준 2 & 3)
- **레이아웃:** **행(Row) = 상태(State), 열(Column) = 프레임** 구조로 그리며, 좌상단 기준 왼쪽에서 오른쪽, 위에서 아래 순으로 정렬합니다. 사용하지 않는 끝부분 셀은 투명하게 비워둡니다. (기준 3)

```
             열0         열1         열2         열3
행0 idle     idle_0      idle_1      (비어있음)  (비어있음)
행1 walk     walk_0      walk_1      walk_2      walk_3
행2 trap     trapped_0   trapped_1   (비어있음)  (비어있음)
```

- **시트 전체 크기:** 4열 × 3행 × 80 px = **320 × 240 px** (레이어당 크기).
- **무적(invuln)** 상태는 **시트에 별도 행이 없습니다** — 런타임에 엔진이 `idle`/`walk` 프레임에 알파 55% 효과를 적용하여 그립니다. (기준 4)

### B.2 캐릭터별 두 개의 출력 레이어 (기준 1 — 의미에 따른 색상 구분)

각 캐릭터는 완벽히 동일한 기하 구조를 가진 두 장의 시트 파일을 쌍으로 가집니다:

1. **`<id>_base.png`** — **무채색 그레이스케일** 스프라이트 (형태 + 셀 셰이딩 + 윤곽선). 색상이 들어가면 안 됩니다. **팀 색상이 칠해질 영역**(옷, 에이프런, 멜빵바지 등)은 중간 명도 구간인 **`L≈45–55 %`** 범위 내의 단일 회색 톤으로 채워 피부(`L≈70–85 %`), 소품, 외곽선(`L≈0–10 %`)과 구별되어야 합니다. 그래야 명도 기반 선택을 통해 마스크를 정확하고 뚜렷하게 분리해낼 수 있습니다.
2. **`<id>_mask.png`** — **팀 색상 마스크**: 칠할 영역만 포함하며 **프리멀티플라이드 알파(Premultiplied-alpha)** 포맷으로 내보냅니다. (RGB 값을 투명도 A와 미리 곱해둠). 이렇게 해야 1 px 두께의 부드러운 안티에일리어싱 테두리 영역이 합성될 때 검거나 밝은 외곽선 노이즈(edge-bleed) 없이 깔끔하게 연출됩니다. 완전히 칠할 곳은 흰색(불투명), 칠하지 않을 곳은 투명(검은색)이며 외곽선 경계는 1 px 단계를 두고 부드럽게 감쇠 처리합니다.

**런타임 합성 규칙** (나중에 구현될 코드 명세): `final_rgb = base_rgb ⊕ (team_colour × mask_coverage)`. 프리멀티플라이드 공간에서 multiply/overlay 블렌드를 적용합니다 (이때 `team_colour = TEAM_COLORS[p.id % size]`). 이를 통해 캐릭터 의상은 각 팀 고유의 색으로 자연스럽게 입혀지면서도 원본 파일 자체에는 어떤 색상 정보도 포함하지 않게 되며, 색약 플레이어는 스프라이트 발판 근처의 `TeamMarker` 도형을 보고 팀을 쉽게 구별할 수 있습니다.

### B.3 "transparent" 단어 없이 투명 PNG 만들기 (기준 2)

에셋 작업 시 아래 두 가지 방식 중 하나를 택하고 기록을 남깁니다 (§9):

- **기본 방식 — 듀얼 매트(Dual-matte) 추출.** 동일한 시드 및 프롬프트로 각 프레임을 **두 번 렌더링**합니다. 한 번은 순수 흰색 배경(`{WHITE}`), 다른 한 번은 순수 검은색 배경(`{BLACK}`). 두 결과를 픽셀 단위로 대조하여 원본 알파 채널과 컬러 값을 복원합니다 (`alpha = 1 - (white - black)`, 원본 컬러 = 검은색 배경 이미지 값 / 알파). 이 방식은 깃털 같은 가장자리 외곽선 부근의 알파값을 정확히 계산해 주며, 프롬프트에 `transparent` 단어를 쓸 필요가 없습니다. 복원 후 1 px 가드 패딩을 적용하여 80 px 규격으로 다듬습니다.
- **대안 방식 — 레이어 알파 지원 모델.** 알파 채널 출력을 지원하는 생성 모델 및 도구를 사용합니다. 이 경우에도 프롬프트에는 `transparent` 단어를 **절대** 쓰지 마십시오.

**내보내기 규격:** PNG-32 형식, 채널당 8비트, 무손실 압축. `*_base.png` 파일은 일반 알파(Straight alpha)를 사용하고 `*_mask.png` 파일은 **프리멀티플라이드 알파(Premultiplied alpha)** 방식을 적용합니다. 색상 프로파일(ICC)은 포함하지 않고 기본 sRGB를 기준으로 합니다.

### B.4 Godot 임포트 설정 유의사항

- 프로젝트 렌더러는 `gl_compatibility` 기준입니다. 시트 이미지는 `CompressedTexture2D` 포맷, **무손실(Lossless)** 압축으로 설정하고, 밉맵은 **비활성화(Off)**합니다. 필터 설정은 취향에 맞춰 조정하되 Nearest 필터를 쓰면 2:1 축소 시에도 셀 셰이딩 테두리가 뭉개지지 않고 선명하게 유지됩니다.
- `*_base.png` 파일 임포트 설정에서 **"Fix Alpha Border"** 옵션을 활성화하여 1 px 투명 테두리가 필터링 과정에서 검은 그라데이션 노이즈로 묻어 나오는 현상을 예방합니다.
- 마스크 맵은 텍스처 데이터로 쓰이므로, sRGB→Linear 변환이 적용되지 않도록 무보정으로 임포트하여 오차를 줄입니다.

### B.5 색약 대응 레이어 구조 (기준 1 & 5 — 독립적인 두 채널 설계)

캐릭터 정보와 팀 정보를 독립적으로 설계하여 혼선이 없도록 합니다:

- **캐릭터의 정체성** (5가지 고수 직업) → `*_base.png`에 그려진 **그레이스케일 실루엣 및 소품** 형태. 색상이 전혀 없는 상태에서도 눈찌푸림/탈색 테스트(Squint/Desaturate test)를 통과해야 합니다.
- **팀의 정체성** (최대 8개 팀) → 마스크를 통해 입혀지는 **팀 색상** 및 이와 독립적으로 드로우되는 **`TeamMarker` 도형 배지**. 통합 연동 시 도형 배지(스프라이트 발판 아래 영역 혹은 모퉁이 배지 형태)를 누락 없이 그려서, 색상이 보이지 않아도 아군과 적군을 완벽히 파악할 수 있도록 만듭니다. 플레이어 번호 텍스트 역시 유지됩니다.

스프라이트는 기존 플레이어 위치 표시 마커를 보강하는 요소이며, 기존의 도형 마커 디자인을 완전히 대체하거나 배제하지 않습니다.

### B.6 일관성 유지 프로토콜 (기준 6)

에셋 일관성을 위해 아래 3가지 환경 변수를 고정하고 §9 로그에 기록합니다:

1. **단일 모델, 동일 버전.** 생성 모델 명칭, 버전 정보, 샘플러 설정, CFG 스케일 및 Step 수를 고정합니다. 작업 진행 중간에 설정을 바꾸지 않으며, 일부 프레임을 재작성할 때도 동일한 조건으로 재생성합니다.
2. **기준 앵커 에셋 고정.** 인간이 최종 승인한 **Menty (멘티)의 `idle_0`** 프레임 이미지가 전체 프로젝트의 스타일 기준점이 됩니다. 다른 캐릭터나 모션 프레임을 생성할 때 이 이미지를 참조 조건(img2img, Reference-only, IP-Adapter 등)으로 삼아 고정된 참조 가중치로 생성합니다.
3. **결정론적 시드 관리.** 기준 앵커 이미지에 기본 시드값 `S`를 부여하고, 다른 프레임들은 `S + 프레임 인덱스`와 같이 **결정론적으로 계산된 시드**를 사용합니다. 캐릭터 세부 묘사와 포즈 프롬프트만 변경하여 일관성을 확보합니다. 듀얼 매트용 흰색/검은색 한 쌍은 당연히 완전히 동일한 시드를 공유해야 합니다.

### B.7 눈찌푸림 / 탈색 가독성 테스트 (기준 5)

5개 캐릭터는 색상 정보 없이도 게임 화면 스케일에서 직관적으로 구분되어야 합니다:

1. 각 캐릭터의 `*_base.png` 중 `idle_0` 프레임을 보드 바닥 색상(`#16243f`) 위에 합성하고, 게임 화면 수준인 **44 px 셀** 및 실제 표시 영역 규격(직경 약 33 px)으로 축소합니다.
2. **눈찌푸림 테스트:** 이미지에 약 1.5 px 반경의 가우시안 블러를 적용합니다. **탈색 테스트:** 원래 무채색이므로 형태(실루엣과 실루엣 바깥으로 튀어나온 소품 모양)에만 의존해 구별 가능한지 확인합니다.
3. **합격 기준:** 슬림형(Sudsy) / 덩치형(Tote) / 장신형(Rolly) / 단정형(Menty) / 소형(Paws) 총 5가지 외형이 서로 혼동을 주지 않아야 하며, 일반 테스터 5명 중 4명 이상이 색상 없는 44 px 썸네일만 보고 5가지 직업을 올바르게 매칭할 수 있어야 합니다.
4. 프레임을 재작성할 때마다 이 테스트를 반드시 재수행합니다 (AI 일괄 생성 시 형태적 일관성이 무너지는 경우가 가장 흔합니다).

### B.8 매니페스트 (시트 규격 계약)

```json
{
  "cell": 80,
  "board_cell": 44,
  "padding": 1,
  "anchor_bottom_center": true,
  "cols": 4,
  "rows": ["idle", "walk", "trapped"],
  "frames": { "idle": 2, "walk": 4, "trapped": 2 },
  "derived_states": { "invuln": "runtime 0.55 alpha over active idle/walk frame" },
  "layers": { "base": "straight-alpha grayscale", "mask": "premultiplied team-colour coverage" },
  "characters": ["cleaning", "moving", "interior", "lesson", "pet"],
  "files": ["<id>_base.png", "<id>_mask.png"],
  "team_hues_for_mask_qa": [
    "#e5484d", "#30a46c", "#3b82f6", "#f5a623",
    "#a855f7", "#06b6b6", "#ec4899", "#eab308"
  ]
}
```

---

## 7. 필수 수동 QA 검증 (기준 7)

모든 에셋 시트는 배포 전에 인간 검수자의 체크리스트 확인을 거쳐 서명해야 합니다:

- [ ] **무채색 유지** — `*_base.png`가 완전히 그레이스케일인지 확인 (포토샵/GIMP 등 그래픽 에디터의 히스토그램 채도 0 검증). 픽셀 자체에 조금이라도 컬러 톤이 들어가면 안 됩니다.
- [ ] **마스크 검증** — `*_base.png`와 `*_mask.png`를 레이어로 올려 8가지 팀 색상을 적용했을 때 채색 경계가 실루엣 안쪽으로 올바르게 들어오는지, 테두리에 원치 않는 오버랩이나 어두운 띠(edge-bleed)가 없는지 검증합니다.
- [ ] **알파 및 여백** — 각 프레임 사방에 1 px 이상의 투명 여백이 보장되는지 확인. 축소 필터 적용 시 엣지 번짐이 없는지 확인. 갇힘 프레임에 물풍선 원이나 링이 포함되어 있지 않은지 확인합니다.
- [ ] **눈찌푸림/탈색 테스트** — §B.7 합격 기준 달성 여부 확인. 색상 없이 44 px 크기에서 5가지 캐릭터가 한눈에 식별되는지 확인합니다.
- [ ] **일관성 검증** — 고정된 생성 조건과 레퍼런스 가중치를 적용하여, 5개 캐릭터 모두 한 세트(선 두께, 셰이딩 스타일, 비율, 광원 방향 등)의 느낌을 유지하는지 확인합니다.
- [ ] **프레임 구성 준수** — 대기(2), 이동(4), 갇힘(2) 프레임이 빠짐없이 포함되었는지 확인합니다. 무적 상태가 별도 행이 아닌 기존 프레임의 알파 감쇠 55%에서도 가독성을 보장하는지 직접 적용해 봅니다.
- [ ] **문자 제외** — 이미지 본문에 문자, 기호, 숫자가 포함되지 않았는지 확인합니다 (§10).
- [ ] **출처 기록** — §9 표에 해당 에셋의 배치 데이터를 작성하고 서명합니다.

## 8. 무적 상태 가독성 안내

엔진 렌더러가 무적 상태일 때 스프라이트 알파를 `0.55`로 변환해 그립니다. 어두운 격자판 위에서 55% 불투명도로 표현되더라도 캐릭터 아웃라인과 팀 채색 영역의 형태가 충분히 식별될 수 있도록 선의 두께와 마스크 칠 농도를 조절해야 합니다. 이를 검증 단계에서 직접 오버레이하여 가독성을 확인하고, 별도의 무적 모션 프레임은 제작하지 않습니다.

## 9. 에셋 출처 / 서비스 약관 로그 (기준 7)

에셋 배치 생성 시마다 아래 표의 한 행을 작성하여 에셋과 함께 아카이브합니다. 생성 도구의 사용 약관이 **상업적 이용**을 허용하고 출력물에 대한 권리를 주장하지 않는지 검토해야 하며, 가급적 **AI 학습 제외(Training opt-out)** 옵션을 제공하는 도구를 사용합니다. 이는 브랜드의 독창성을 확보하기 위한 수칙([`docs/BRAND.md`](BRAND.md) §3)에 따른 필수 절차입니다.

| 생성일 | 에셋 구분 | 사용 도구 + 버전 | 생성 모델 + 버전 | 샘플러 / CFG / Steps | 시드값 정보 | 참조 앵커 정보 | 프롬프트 원문 / 해시 | 배경 추출 방식 | 약관(ToS) URL | 상업적 이용 가능 여부 | 학습 제외 여부 | 검수자 | 서명 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | | | | | | | |

## 10. 다국어(i18n) — 에셋에는 해당 없음

캐릭터 스프라이트에는 텍스트 정보가 전혀 포함되지 않으므로(§A.1/§A.2 규칙으로 텍스트 렌더링 강제 배제), 국가/언어별 이미지 파일 분기가 필요 없습니다. 프로젝트의 지원 로케일 세트({`en`, `ko`})는 게임을 감싸고 있는 UI 텍스트 영역에만 적용되며, 이는 번역 카탈로그 파일(`localization/ui_strings.csv`)을 통해 처리되므로 본 리소스 작업과는 무관합니다.

---

## 승인 기준 체크리스트

| # | 승인 기준 항목 | 명세 내 적용 영역 |
| --- | --- | --- |
| (A) | 캐릭터 정보 메모를 기초로 각 포즈와 소품을 명시한 캐릭터별 프롬프트 제공 | §A.1–A.4 (characters.md 명세와 동기화된 5개 프롬프트 명세) |
| 1 | 의미에 따른 색상 구분 — 그레이스케일 스프라이트와 **프리멀티플라이드** 팀 마스크 분리, 런타임 채색 처리 | §0, §B.2, §B.5 |
| 2 | 1 px 가드 패딩이 포함된 투명 PNG, 프롬프트에 `transparent` 키워드 배제 (듀얼 매트 복원 혹은 알파 레이어 내장 모델 활용) | §B.1, §B.3, §A.1 |
| 3 | 격자 크기(`CELL=44`)를 감안한 80 px 규격의 프레임 셀, 상태별 행과 프레임별 열 구조 고정 | §B.1 |
| 4 | 실제 게임 렌더러가 지원하는 모션(대기, **이동(신규)**, 갇힘, 알파 감쇠 기반 무적 상태)만 제작 | §0 테이블, §B.1, §8 |
| 5 | 서로 명확히 구분되는 5종의 실루엣, 44 px 바나나 바둑판 스케일에서 색상 없이 완벽히 구별 가능한 가독성 검증 | §A.3, §B.5, §B.7 |
| 6 | 기준 앵커 에셋 고정, 결정론적 시드값 연산, 일관된 생성 파라미터를 사용해 하나의 세트감 완성 | §B.6 |
| 7 | 인간에 의한 최종 수동 검수 절차 준수, 에셋 도구 출처/약관 로그 기록 보관, 이미지 내 문자 포함 배제 | §7, §9, §10 |

## 검증

본 파일은 **문서 전용 명세**로 개별 코드나 엔진 파일(`.gd`, `.tscn`, `.godot`)은 직접 수정하지 않았습니다. 따라서 기존에 작동하던 게임 빌드와 유닛 테스트, 시뮬레이션은 아무런 영향을 받지 않고 이전과 동일하게 유지됩니다:

```sh
GODOT=/Applications/Godot.app/Contents/MacOS/Godot
"$GODOT" --headless --path . --import
"$GODOT" --headless --path . --script res://tests/run_tests.gd   # 규칙 + 라인업 + 프로필 검증
"$GODOT" --headless --path . --script res://tests/smoke_ui.gd    # 로비/게임/연결 UI 검증
```

명세 자체의 적합성은 위의 **승인 기준 체크리스트** 대조를 통해 보증하며, 향후 디자인 리소스가 완성되어 투입될 때 §7의 **수동 QA 검증 항목**을 적용해 에셋의 완성도를 최종 확인합니다.
