# AttentionTimer

맥 화면 위에 항상 떠있는 집중 타이머. 행동을 막지는 않고, **보이게** 해서 망설이게 만든다.

> *An always-on-top focus timer for macOS that doesn't block anything — it just watches, turns red when you drift, and keeps the count where you can see it.*

```
   ╭──────────────────────────────────────╮
   │  ◔  24:13            집중 중          │   ← 평소
   ╰──────────────────────────────────────╯

   ╭──────────────────────────────────────╮
   │  ●  24:13     youtube.com · 0:42 흘림 │   ← 딴짓 감지 (빨강 + 숨쉬듯 커짐)
   ╰──────────────────────────────────────╯
```

## 왜 만들었나

앱 차단기는 결국 뚫는다. 예외를 추가하거나, 꺼버리거나, 폰으로 옮겨간다.
그래서 막는 대신 **눈에 띄는 자리에 계속 떠 있게** 했다.
유튜브를 열 수는 있는데, 그 순간 화면 위 알약이 빨개지고 흘린 시간이 초 단위로 올라간다.
막지 않으니 반발도 없고, 보이니까 그냥 하기가 좀 그렇다.

## 요구사항

- macOS 13 (Ventura) 이상 — 개발/테스트는 macOS 15.6
- Xcode Command Line Tools (`xcode-select --install`) — `swiftc` 만 있으면 됨

Xcode 앱 자체나 외부 패키지는 필요 없다. 의존성 0개.

## 실행

```bash
git clone https://github.com/jaylions/AttentionTimer.git
cd AttentionTimer
```

**터미널 없이 쓰는 법 (권장)** — 한 번만:

```bash
./install.sh
```

`/Applications/AttentionTimer.app` 으로 설치된다. 이후로는

- **Launchpad / Spotlight(⌘Space)에서 "AttentionTimer"** 로 실행
- 또는 Finder에서 **더블클릭**
- **로그인할 때 자동 실행** → 메뉴바 `◷` → *로그인 시 자동 실행* 체크

한 번 켜두면 그냥 계속 떠있는 물건이라 사실 자동 실행 켜놓는 게 제일 편하다.

**개발용** (코드 고칠 때):

```bash
./build.sh   # 컴파일
./run.sh     # 빌드된 걸 실행
```

Xcode 프로젝트 없음. `swiftc` 한 줄로 `.app` 번들이 만들어진다.
`/Applications`에 설치돼 있으면 `build.sh`가 그 사본도 자동으로 같이 갱신한다.

## 어떻게 동작하나 (LLM·API 키 없음, 전부 로컬)

| 하는 일 | 쓰는 것 | 권한 |
|---|---|---|
| 지금 맨 앞 앱이 뭔지 | `NSWorkspace.didActivateApplicationNotification` | 필요 없음 |
| 브라우저 열린 탭 주소 | `osascript` 한 줄 (AppleScript) | 첫 실행 때 "자동화 허용" 1회 |
| 딴짓 판정 | 번들 ID / URL 문자열 **단순 대조** | — |

네트워크 요청 0. 주소는 로컬에서 문자열 비교만 하고 버린다.

**지원 브라우저** (탭 URL 읽기): Dia, Arc, Chrome, Safari, Edge, Brave, Vivaldi, 웨일.
Firefox는 AppleScript로 URL을 노출하지 않아 앱 단위 감지만 된다.

> ⚠️ `./build.sh`로 다시 빌드하면 앱 서명이 바뀌어서 "자동화 허용" 팝업이 다시 뜰 수 있다. 코드 고칠 때마다 한 번씩 허용해주면 됨.

## 화면 위 동작

- **항상 최상단** — 풀스크린 유튜브 위에도 뜬다 (`.screenSaver` 레벨 + `fullScreenAuxiliary`)
- **모든 데스크탑(Space)에 따라다님**
- **드래그로 위치 이동** — 위치는 저장됨. 되돌리려면 메뉴바 → 알약 위치 초기화
- **클릭해도 작업 앱 포커스를 뺏지 않음** (`nonactivatingPanel`)
- 마우스 올리면 오른쪽에 ▶ / ↺ / ✕ 버튼이 나타남. 알약 아무데나 클릭 = 시작/일시정지

## 딴짓 감지 규칙

1. 앞에 온 앱이 `distractionApps`에 있거나, 브라우저 탭 URL이 `distractionSites`의 문자열을 포함하면 → 후보
2. **6초(`graceSeconds`) 넘게 머물러야** 실제 경고. 잠깐 스치는 건 봐준다
3. 경고 발동 → 알약이 빨개지고 커지며 흘린 시간을 초 단위로 세기 시작, `흔들림 N회` 카운터 +1
4. 돌아오면 즉시 원상복구. 단 카운터는 안 지워진다 — 오늘 몇 번 흔들렸는지가 계속 보임

집중 중(`focusing`)일 때만 감지한다. 일시정지·대기 중엔 아무것도 안 본다.

## 딴짓 목록 관리

**JSON 안 건드려도 된다.** 메뉴바 `◷` 아이콘을 누르면:

```
  집중 시작 (25분)
  ─────────────────────────────
  오늘 흔들림 2회 · 4분
  ─────────────────────────────
  ＋ 딴짓에 추가:  KakaoTalk        ← 지금 앞에 있던 앱
  ＋ 딴짓에 추가:  youtube.com      ← 지금 보던 사이트
  딴짓 목록 관리                 ▸  ← 클릭해서 빼기
  ─────────────────────────────
  기록 파일 열기
  설정 파일 열기 (JSON)
  ...
  ☑ 로그인 시 자동 실행
```

딴짓하다 걸렸을 때 메뉴바만 누르면 **"＋ 딴짓에 추가: 그거"** 가 이미 떠 있다.
메뉴를 열어도 직전에 보던 앱/사이트를 기억하기 때문 (자기 자신은 무시).
`딴짓 목록 관리 ▸` 안에서 항목을 클릭하면 목록에서 빠진다.

바꾼 내용은 바로 `config.json`에 저장되고 즉시 적용된다.

## 설정 (세밀한 조정)

`~/.attentiontimer/config.json` — 메뉴바 → **설정 파일 열기** / 고친 뒤 **설정 다시 읽기**

| 키 | 뜻 |
|---|---|
| `focusMinutes` | 한 세션 길이 (기본 25) |
| `graceSeconds` | 딴짓 유예 시간 (기본 6초) |
| `watchBrowserURL` | 브라우저 탭 감시 on/off. `false`면 자동화 권한 아예 안 씀 |
| `logAllSites` | `true`로 하면 집중 중 **방문한 모든 사이트**를 기록에 남김 (기본 `false`) |
| `distractionApps` | 차단 앱 번들 ID 목록 |
| `distractionSites` | 차단 사이트 문자열 (URL에 포함되면 걸림) |

내 앱의 번들 ID 찾기:

```bash
./ids.sh
```

## 기록

`~/.attentiontimer/events.jsonl` — 한 줄에 한 이벤트, 그냥 텍스트라 나중에 뭘로든 분석 가능.

```json
{"day":"2026-08-24","type":"distraction_start","app":"Google Chrome","detail":"youtube.com","t":"..."}
{"day":"2026-08-24","type":"distraction_end","app":"Google Chrome","seconds":73,"t":"..."}
{"day":"2026-08-24","type":"session","completed":true,"planned_sec":1500,"distracted_sec":120,"warnings":3,"t":"..."}
{"day":"2026-08-24","type":"site","host":"github.com","app":"Dia","t":"..."}   // logAllSites=true 일 때만
```

`logAllSites`를 켜면 집중 시간에 들른 사이트가 호스트 단위로 남는다 (호스트가 바뀔 때만 한 줄, 전체 URL은 저장 안 함).
나중에 "내가 집중한다며 어디를 돌아다녔나" 보기 좋음:

```bash
grep '"type":"site"' ~/.attentiontimer/events.jsonl | python3 -c '
import sys,json,collections
c=collections.Counter(json.loads(l)["host"] for l in sys.stdin)
for h,n in c.most_common(20): print(f"{n:4}  {h}")'
```

오늘 흔들린 횟수/시간은 앱 시작할 때 이 파일에서 다시 읽어온다. 껐다 켜도 안 리셋됨.

## 구조

```
src/main.swift    전부 여기 (Swift + AppKit, ~700줄)
build.sh          swiftc → AttentionTimer.app 번들
install.sh        /Applications 로 설치
run.sh            빌드된 앱 실행
ids.sh            실행 중인 앱들의 번들 ID 출력
```

## 라이선스

MIT. 마음대로 가져다 쓰세요.
