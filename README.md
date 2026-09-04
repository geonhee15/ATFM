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
- **체크리스트** 탭: 적고 Enter로 추가, 체크로 완료, 더블클릭 수정, 호버 ✕ 삭제, 완료 항목 접기/한 번에 지우기.
  `~/Library/Application Support/ATFM/checklist.json` 에 자동 저장
- **절전 방지** 탭: 스위치 하나로 자동 잠자기 방지(계속 · 30분 ~ 8시간), 화면 켜 둠 옵션,
  덮개를 닫아도 유지(`pmset disablesleep`, 관리자 암호 필요). ATFM 종료 시 자동 해제
- **시스템** 탭
  - CPU(코어별 포함) · GPU · 배터리 사용량과 최근 1분 추이
  - CPU / 배터리 온도 (Apple Silicon 내부 센서, 권한 불필요)
  - **앱별 사용량**: 헬퍼 프로세스를 부모 앱으로 묶어서(Activity Monitor 방식) CPU · 메모리 순으로 표시
  - 메모리 압력, 앱/사용 중/압축/캐시/스왑 분해, 가동 시간
- **네트워크** 탭
  - 현재 다운로드/업로드 속도와 추이, 인터페이스 · IP, 세션 누적량
  - **앱별 사용량**: `nettop` 을 스트리밍해서 2초마다 앱별 ↓↑ 속도 표시
  - 속도 측정: Cloudflare 서버로 다운로드/업로드 Mbps 와 지연 시간 측정 (버튼을 눌렀을 때만)
- **빠른 동작** 탭
  - ATFM 다크 모드: 시스템 설정은 그대로 두고 이 창만 라이트/다크/시스템으로 전환
  - 키보드 백라이트 켜기/끄기 (CoreBrightness, 권한 불필요)
  - 화면 잠금(⌃⌘Q 와 동일하게 암호 화면으로), 화면 보호기 시작, 디스플레이 끄기
  - 휴지통 비우기(확인 후, Finder 자동화 권한 1회 요청), 모든 외장 디스크 추출
  - 숨겨진 파일 보기 · 데스크탑 아이콘 가리기 (Finder 재시작)
- **파일 변환** 탭: 파일을 끌어다 놓거나 골라서 한 번에 변환
  - 이미지 → PNG · JPEG · HEIC · AVIF · TIFF · GIF · BMP (품질 슬라이더, 최대 크기 축소, 회전 정보 반영). macOS ImageIO 사용
  - 영상 → MP4/MOV (H.264 · HEVC, 하드웨어 인코딩) · MKV · WebM(VP9) · 움직이는 GIF, 해상도/화질 선택, 영상에서 오디오만 추출
  - 오디오 → MP3 · M4A(AAC) · WAV · FLAC · AIFF · OGG(Opus), 비트레이트 선택
  - 영상·오디오는 Homebrew `ffmpeg`(`/opt/homebrew/bin` 또는 `/usr/local/bin`)를 쓰고, 없으면 AVFoundation으로 MP4/MOV/M4A만 지원
  - 저장 위치: 원본 폴더(같은 확장자면 `-변환` 붙임) · 다운로드 · 지정 폴더, 진행률 · 중단 · Finder에서 보기
- **미니 플레이어** 탭: Spotify(앱·웹 플레이어)나 다른 앱이 노래를 재생하면 화면 구석에 작은 플레이어가 뜹니다
  - 앨범아트 · 제목 · 아티스트 · 진행 바 · 이전/재생·일시정지/다음, 항상 위, 모든 Space에서 표시, 드래그로 이동
  - ✕를 누르면 ATFM에서 다시 켤 때까지 숨김. 표시할 소스(Spotify 앱만 / + 브라우저 / 모든 앱), 일시정지 표시, 위치 설정
  - 🎤 버튼으로 아래에 **가사** 박스 펼치기: LRCLIB(무료, 키 불필요)에서 찾아 타임라인 싱크가 있으면 현재 줄을 강조하며
    자동 스크롤(줄 클릭 → 그 위치로 이동), 없으면 일반 가사. 결과는 `Application Support/ATFM/lyrics/`에 캐시
  - 싱크 보정: −/+ 버튼으로 0.5초 단위 누적 조정, 값을 누르면 0으로. 곡별로 기억
  - macOS의 Now Playing(MediaRemote)은 일반 앱에 정보를 주지 않아서, Apple 서명 `perl`이 작은 브리지
    (`ATFMMediaRemote.dylib` + `mediaremote.pl`)를 로드해 JSON으로 중계합니다. 권한 요청 없음
- **간편 AI** 탭: Gemini 미니 채팅. API 키를 한 번 넣으면 스트리밍으로 답하고, 모델 목록 불러오기/선택
  (쓸 수 없는 모델이면 계정에서 쓸 수 있는 flash 모델로 자동 교체), Google 검색 그라운딩 토글(기본 켜짐,
  날씨·뉴스 같은 실시간 질문에 출처와 함께 답변), 답변 복사, 대화 기록은 최근 20개까지 보관.
  키와 대화는 이 Mac에만 저장(`gemini-chats.json`)

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
| `ATFM_TAB=system` | 시작 탭 (`clipboard` · `checklist` · `awake` · `system` · `network` · `actions` · `convert` · `player` · `ai` · `settings`) |
| `ATFM_SNAPSHOT_MINI=/path.png` | 미니 플레이어 창을 PNG로 저장 |
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
├── Checklist/   체크리스트 저장소 (JSON)
├── Awake/       절전 방지 (IOPMAssertion, pmset disablesleep)
├── AI/          Gemini REST 클라이언트(SSE 스트리밍) + 대화 저장
├── Convert/     파일 변환 (ImageIO · ffmpeg · AVFoundation 엔진, 변환 큐)
├── NowPlaying/  Now Playing 브리지 클라이언트, 미니 플레이어 패널, LRCLIB 가사
├── System/      CPU·메모리·GPU·배터리·온도 프로브, 프로세스별 샘플러, 시스템 모니터
├── Network/     인터페이스 카운터 + nettop 스트리밍, 속도 측정
├── Actions/     빠른 동작 (백라이트, 잠금, Finder 설정, 휴지통, 디스크 추출)
├── UI/          SwiftUI 화면 (탭별 화면 전부)
└── Support/     설정 키, 앱 아이콘 캐시
Sources/MediaRemoteBridge/Bridge.swift   perl이 로드하는 MediaRemote 브리지 (dylib로 따로 빌드)
```

## 앞으로

ATFM 은 기능을 계속 추가하는 것을 전제로 만들어졌습니다. 상단 탭바에 아이콘 하나를 더하고
`AppTab` 에 case 를 추가하면 새 기능 화면이 붙습니다.
