# ATFM — Additional Things For Mac

맥을 쓰면서 "이거 하나 더 있었으면…" 싶었던 기능들을 메뉴 막대 앱 하나에 모아가는 프로젝트입니다.
지금은 첫 번째 기능인 **클립보드 기록**이 들어 있습니다.

## 지금 되는 것

- 메뉴 막대에 조용히 상주하는 아이콘 (Dock 아이콘 없음)
- 아이콘을 누르면 아래로 부드럽게 내려오는 **말풍선 팝업**
  - 다른 앱으로 전환하거나 바깥을 클릭해도 닫히지 않고, 아이콘을 다시 누를 때까지 계속 떠 있습니다 (Esc로도 닫힘)
- 클립보드 기록
  - ⌘C 로 복사한 텍스트 · 이미지 · 파일(Finder)을 모두 저장
  - **어떤 앱에서** 복사했는지 앱 아이콘과 이름으로 표시
  - 날짜별로 묶고, 항목마다 **시:분:초** 표시
  - 내용 / 앱 이름으로 검색, 앱 · 종류(텍스트/이미지/파일)로 필터
  - 항목 클릭 → 다시 클립보드로 복사
  - 삭제: 하나씩(hover 후 ✕), 선택해서 여러 개, 전체 삭제
  - 암호 관리자에서 복사한 비밀 값(`org.nspasteboard.ConcealedType`)은 기록하지 않음
- 설정: 최대 보관 개수, 중복 항목 위로 올리기, 이미지/파일 저장 여부, 로그인 시 자동 실행
- **시스템** 탭
  - CPU(코어별 포함) · GPU · 배터리 사용량과 최근 1분 추이
  - CPU / 배터리 온도 (Apple Silicon 내부 센서, 권한 불필요)
  - **앱별 사용량**: 헬퍼 프로세스를 부모 앱으로 묶어서(Activity Monitor 방식) CPU · 메모리 순으로 표시
  - 메모리 압력, 앱/사용 중/압축/캐시/스왑 분해, 가동 시간
- **네트워크** 탭
  - 현재 다운로드/업로드 속도와 추이, 인터페이스 · IP, 세션 누적량
  - **앱별 사용량**: `nettop` 을 스트리밍해서 2초마다 앱별 ↓↑ 속도 표시
  - 속도 측정: Cloudflare 서버로 다운로드/업로드 Mbps 와 지연 시간 측정 (버튼을 눌렀을 때만)

데이터는 `~/Library/Application Support/ATFM/clipboard.sqlite` 에 SQLite로 저장됩니다.

## 빌드

Xcode 없이 Command Line Tools만 있으면 됩니다 (macOS 14+, Swift 5.9+).

```bash
./build.sh          # build/ATFM.app 생성
./build.sh --run    # 빌드 후 실행
```

`build.sh` 는 `swiftc` 로 직접 컴파일한 뒤 `.app` 번들을 조립하고 ad-hoc 서명합니다.
Xcode가 있다면 `Package.swift` 를 열어서 빌드해도 됩니다.
첫 빌드는 SDK 모듈 캐시(`build/ModuleCache`)를 만드느라 몇 분 걸리고, 그 다음부터는 수 초면 끝납니다.

개발용 환경 변수:

| 변수 | 동작 |
|---|---|
| `ATFM_AUTO_SHOW=1` | 실행 직후 말풍선을 바로 엽니다 |
| `ATFM_SNAPSHOT=/path/out.png` | 잠시 뒤 말풍선 창을 PNG로 저장합니다 (화면 기록 권한 불필요) |
| `ATFM_SNAPSHOT_DELAY=6` | 스냅샷까지 기다리는 초 (기본 2) |
| `ATFM_TAB=system` | 시작 탭 (`clipboard` · `system` · `network` · `settings`) |
| `ATFM_PANEL_HEIGHT=1040` | 말풍선 높이 (기본 640) |

`Scripts/dev-run.sh system` 처럼 탭 이름을 주면 위 조합으로 실행하고 `build/snap-<tab>.png` 를 남깁니다.
`ATFM --probe` 는 센서 · GPU · 메모리 · 앱별 사용량 샘플을 터미널에 출력합니다.

```bash
Scripts/dev-run.sh network
```

## 구조

```
Sources/ATFM
├── App/         진입점, 메뉴 막대 아이템, 말풍선 패널(NSPanel + NSVisualEffectView)
├── Clipboard/   모델, SQLite 저장소, 페이스트보드 감시, 뷰모델
├── System/      CPU·메모리·GPU·배터리·온도 프로브, 프로세스별 샘플러, 시스템 모니터
├── Network/     인터페이스 카운터 + nettop 스트리밍, 속도 측정
├── UI/          SwiftUI 화면 (루트/탭바, 클립보드, 시스템, 네트워크, 설정)
└── Support/     설정 키, 앱 아이콘 캐시
```

## 앞으로

ATFM 은 기능을 계속 추가하는 것을 전제로 만들어졌습니다. 상단 탭바에 아이콘 하나를 더하고
`AppTab` 에 case 를 추가하면 새 기능 화면이 붙습니다.
