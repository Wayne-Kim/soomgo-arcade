# 캐릭터 고유 스킬 — 사용법 및 명세서

각 캐릭터는 **고유 스킬(Unique Skill)** 하나를 가집니다. 스킬은 캐릭터가 바라보는 방향(`facing`)을 기준으로 즉시 발동되며, 성공적으로 발동되면 캐릭터별 **쿨다운**이 시작됩니다 (쿨다운 중에는 다시 사용할 수 없습니다).

**SSOT (단일 진실 공급원)**
- 캐릭터 ↔ 스킬 매핑: [`scripts/core/Simulation.gd`](../scripts/core/Simulation.gd) (`SKILLS` 상수)
- 스킬 구현체: [`scripts/core/skills/`](../scripts/core/skills/) (각 스킬은 [`CharacterSkill`](../scripts/core/skills/CharacterSkill.gd)를 상속)
- 입력 키 바인딩: [`project.godot`](../project.godot) (`<prefix>_skill` 액션) — 입력 흐름은 [`docs/NETWORKING.md`](NETWORKING.md) 참고

> 쿨다운 시간은 틱(tick) 단위로 정의되며, 시뮬레이션은 **초당 60틱** 고정 스텝으로 동작합니다. 따라서 `240틱 = 4초`입니다.

## 1. 스킬 발동 키

스킬은 **이동/물풍선 설치와 별개의 전용 키**로 발동합니다. 한 기기에서는 한 명만 플레이하며, 키보드 한 가지 조작 스킴을 사용합니다.

| 조작 스킴 | 이동 | 물풍선 설치 | **스킬 발동** |
|---|---|---|---|
| 키보드 (방향키) | `↑ ↓ ← →` | `Space` | **`왼쪽 Shift`** |

- 스킬은 **눌린 순간(just-pressed)** 에만 발동됩니다 — 키를 누르고 있어도 매 틱 연속 발동되지 않습니다.

> **게임 내 안내**: 로비의 캐릭터 선택 화면에서 각 캐릭터를 고르면 미리보기에 **스킬 이름·효과·발동 키**가 함께 표시됩니다 (해당 슬롯의 조작 스킴에 맞는 키를 자동 표시). 따라서 이 문서를 보지 않아도 인게임에서 바로 스킬을 파악할 수 있습니다.
>
> **발동 피드백**: 스킬이 실제로 발동되면 캐스터 위치에 **확장 링 + 스킬 이름**이 잠깐 표시되고 전용 효과음(`skill`)이 재생됩니다. 롤러 코팅의 페인트 바닥은 팀 색으로 칠해지며 지속 시간이 끝나갈수록 서서히 옅어집니다. (렌더 전용 효과이므로 lockstep 결정론에는 영향이 없습니다.)
>
> **쿨다운 표시**: 내 캐릭터 주위에 **쿨다운 회복 링**이 그려집니다 — 쿨다운 중에는 12시 방향부터 시계방향으로 호가 차오르고, 준비되면 밝게 깜빡이는 완전한 링이 됩니다. 하단 정보 패널에도 **"스킬 준비됨"** 또는 **"스킬 N초 후"** 텍스트가 함께 표시됩니다. (모양으로 구분되므로 색약 플레이어도 식별 가능)
- 이동 방향 입력이 없을 때는 마지막으로 바라본 방향을 사용하며, 한 번도 움직이지 않았다면 기본값으로 **아래쪽(`DOWN`)** 을 향해 발동됩니다.
- 스킬은 **이동을 처리하기 전에** 먼저 해석됩니다. 따라서 돌진/넉백 같은 위치 변경 스킬이 같은 틱 안에서 즉시 반영됩니다.
- 온라인 대전에서도 스킬 입력은 1비트로 인코딩되어 결정론적으로 동기화됩니다 ([`scripts/net/InputCmd.gd`](../scripts/net/InputCmd.gd)의 `_SKILL_BIT`).

## 2. 캐릭터별 스킬 명세

| 캐릭터 | 모티프 | 스킬 이름 | 효과 | 쿨다운 | 구현 |
|---|---|---|---|:---:|---|
| **뽀득 (Sudsy)** | 청소 | 미끄덩 대시 (Slippery Dash) | 바라보는 방향으로 최대 **2칸** 순간 돌진. 이동 중이거나 막혀 있으면 멈춤. | 6초 (360틱) | [`SlipperyDash.gd`](../scripts/core/skills/SlipperyDash.gd) |
| **한짐 (Tote)** | 이사 | 짐 밀기 (Cargo Push) | 정면의 **물풍선** 또는 **소프트 블록**을 한 줄로 밀어냄 (숨겨진 파워업도 함께 이동). | 4초 (240틱) | [`CargoPush.gd`](../scripts/core/skills/CargoPush.gd) |
| **데굴 (Rolly)** | 인테리어 | 롤러 코팅 (Roller Coating) | 정면 최대 **3칸** 바닥에 팀 색 페인트를 칠함 (5초 지속). 아군은 빠르게, 적군은 느리게 이동. | 8초 (480틱) | [`RollerCoating.gd`](../scripts/core/skills/RollerCoating.gd) |
| **척척 (Menty)** | 레슨 | 호루라기 (Whistle Blow) | 상하좌우 **2칸** 이내의 모든 플레이어를 바깥쪽으로 밀어내고 **0.5초(30틱) 스턴**. 한 플레이어는 한 번만 피격. | 7초 (420틱) | [`WhistleBlow.gd`](../scripts/core/skills/WhistleBlow.gd) |
| **살금 (Paws)** | 펫케어 | 목줄 회수 (Leash Retrieve) | 정면 최대 **4칸** 으로 목줄을 던져, 물풍선에 갇힌 **아군**을 캐스터 바로 앞으로 끌어와 즉시 구출 + 무적 부여. | 10초 (600틱) | [`LeashRetrieve.gd`](../scripts/core/skills/LeashRetrieve.gd) |

### 발동 실패 조건
스킬은 "월드에 실제로 영향을 준 경우"에만 성공으로 간주되어 쿨다운이 시작됩니다. 다음과 같은 경우 발동이 **무시되며 쿨다운도 소모되지 않습니다**:
- **미끄덩 대시**: 이미 이동 중이거나, 정면이 벽/블록으로 막혀 한 칸도 전진할 수 없을 때.
- **짐 밀기**: 정면에 밀 수 있는 물풍선/소프트 블록이 없거나, 밀어낼 공간이 없을 때.
- **롤러 코팅**: 정면 3칸에 칠할 수 있는 바닥(FLOOR) 타일이 하나도 없을 때.
- **호루라기**: 사거리 안에 다른 플레이어가 한 명도 없을 때.
- **목줄 회수**: 끌어올 자리(캐스터 정면)가 막혀 있거나, 사거리 안에 갇힌 아군이 없을 때.

## 3. 확장 방법 (새 스킬 추가)

스킬 시스템은 [`CharacterSkill`](../scripts/core/skills/CharacterSkill.gd) 인터페이스를 중심으로 SOLID 원칙(SRP/OCP/LSP/DIP)을 따릅니다. 새 캐릭터 스킬을 추가하려면:

1. `scripts/core/skills/` 에 `CharacterSkill`을 상속한 새 스크립트를 만들고 `execute()`와 `get_cooldown_ticks()`를 구현합니다.
   - `execute(sim, caster) -> bool`: 효과를 적용하고, 실제로 영향을 줬으면 `true`를 반환.
   - `get_cooldown_ticks() -> int`: 성공 시 적용할 쿨다운(틱).
2. [`Simulation.gd`](../scripts/core/Simulation.gd)의 `SKILLS` 딕셔너리에 `"<character_id>": preload(...)` 항목을 추가합니다.

기존 `Simulation`/입력 파이프라인은 수정할 필요가 없습니다 — 매핑만 추가하면 됩니다.

## 4. 검증

```sh
GODOT=/Applications/Godot.app/Contents/MacOS/Godot
"$GODOT" --headless --path . --editor --quit          # 전역 클래스 캐시 빌드 (최초 1회)
"$GODOT" --headless --path . --script res://tests/run_tests.gd   # 스킬 동작 검증 포함
```
