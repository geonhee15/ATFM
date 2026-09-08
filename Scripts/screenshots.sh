#!/bin/zsh
# Regenerates docs/screenshots/*.png for the README with sample data (never touches real user data:
# every store is pointed at a scratch folder via ATFM_DEBUG_DATA_DIR; the clipboard is restored after).
#   ./build.sh debug && Scripts/screenshots.sh
set -u
cd "$(dirname "$0")/.."
export LC_ALL=en_US.UTF-8
OUT="$PWD/docs/screenshots"; APP="./build/ATFM.app/Contents/MacOS/ATFM"
D="$(mktemp -d /tmp/atfm-shots.XXXXXX)"
python3 - "$D" <<'PY'
import json,sys,datetime,uuid
D=sys.argv[1]; now=datetime.datetime.now(datetime.timezone.utc)
iso=lambda dt: dt.strftime("%Y-%m-%dT%H:%M:%SZ")
today=datetime.datetime.now()
due1=today.replace(hour=18,minute=0,second=0,microsecond=0).astimezone(); due2=(today+datetime.timedelta(days=1)).replace(hour=10,minute=0,second=0,microsecond=0).astimezone()
lz=lambda dt: dt.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump([
 {"id":str(uuid.uuid4()),"text":"README 스크린샷 올리기","isDone":False,"createdAt":iso(now-datetime.timedelta(hours=1)),"dueAt":lz(due1)},
 {"id":str(uuid.uuid4()),"text":"헬스장 가기","isDone":False,"createdAt":iso(now-datetime.timedelta(hours=2)),"dueAt":lz(due2)},
 {"id":str(uuid.uuid4()),"text":"우유 사기","isDone":False,"createdAt":iso(now-datetime.timedelta(hours=3))},
 {"id":str(uuid.uuid4()),"text":"과제 제출","isDone":True,"createdAt":iso(now-datetime.timedelta(hours=5)),"doneAt":iso(now-datetime.timedelta(minutes=40))},
], open(D+"/checklist.json","w"), ensure_ascii=False)
json.dump([
 {"id":str(uuid.uuid4()),"text":"장보기\n- 우유, 계란\n- 커피 원두 1kg\n- 세제","createdAt":iso(now-datetime.timedelta(minutes=3)),"updatedAt":iso(now-datetime.timedelta(minutes=3))},
 {"id":str(uuid.uuid4()),"text":"ATFM 아이디어: 창 정리, 타이머, 환율","createdAt":iso(now-datetime.timedelta(hours=2)),"updatedAt":iso(now-datetime.timedelta(hours=2))},
 {"id":str(uuid.uuid4()),"text":"회의 15:00 회의실 B","createdAt":iso(now-datetime.timedelta(days=1)),"updatedAt":iso(now-datetime.timedelta(days=1))},
], open(D+"/notes.json","w"), ensure_ascii=False)
json.dump([{"id":str(uuid.uuid4()),"title":"내일 서울 날씨","createdAt":iso(now-datetime.timedelta(minutes=10)),"updatedAt":iso(now-datetime.timedelta(minutes=9)),"messages":[
 {"id":str(uuid.uuid4()),"role":"user","text":"내일 서울 날씨 어때? 우산 챙겨야 해?","date":iso(now-datetime.timedelta(minutes=10))},
 {"id":str(uuid.uuid4()),"role":"model","text":"내일 서울은 **오전에 흐리고 오후 늦게 비**가 올 가능성이 높아요.\n\n- 낮 최고 24°C, 아침 최저 17°C\n- 강수 확률 60% (16시 이후)\n- 바람은 약한 편\n\n오후에 외출 계획이 있으면 **작은 우산**을 챙기는 게 좋겠어요.","date":iso(now-datetime.timedelta(minutes=9)),"sources":[{"title":"기상청 날씨누리","uri":"https://www.weather.go.kr/"}]}]}],
 open(D+"/gemini-chats.json","w"), ensure_ascii=False)
today=datetime.date.today()
def ev(title,d,**kw):
    base={"id":str(uuid.uuid4()),"title":title,"year":d.year,"month":d.month,"day":d.day,"note":"","colorIndex":0,"showsInCalendar":True,"showsInDday":False,"repeatRule":"none","createdAt":"2026-09-01T00:00:00Z"}
    base.update(kw); return base
json.dump([
 ev("팀 회의", today+datetime.timedelta(days=2), hour=15, minute=0),
 ev("치과 예약", today+datetime.timedelta(days=5), hour=10, minute=30, colorIndex=2),
 ev("제주 여행", today+datetime.timedelta(days=12), colorIndex=3, showsInDday=True, endYear=(today+datetime.timedelta(days=16)).year, endMonth=(today+datetime.timedelta(days=16)).month, endDay=(today+datetime.timedelta(days=16)).day),
 ev("헬스장 등록", today, hour=19, minute=0, colorIndex=1),
 ev("사귄 날", datetime.date(2024,3,14), colorIndex=5, showsInCalendar=False, showsInDday=True, repeatRule="yearly", ddayStyle="elapsed", countsStartAsOne=True),
 ev("월급날", datetime.date(2026,1,25), colorIndex=3, showsInCalendar=False, showsInDday=True, repeatRule="monthly"),
 ev("자격증 시험", today+datetime.timedelta(days=40), colorIndex=1, showsInCalendar=False, showsInDday=True),
], open(D+"/dates.json","w"), ensure_ascii=False)
PY
saved_clip="$(pbpaste 2>/dev/null || true)"
shot() {  # shot <tab> <delay> [extra env...]   (SHOT_NAME overrides the output file name)
  local tab=$1 delay=$2; shift 2
  local name="${SHOT_NAME:-$tab}"
  pkill -x ATFM 2>/dev/null; sleep 0.4; rm -f "$OUT/$name.png"
  (env ATFM_DEBUG_DATA_DIR="$D" ATFM_TAB="$tab" ATFM_AUTO_SHOW=1 ATFM_SNAPSHOT="$OUT/$name.png" ATFM_SNAPSHOT_DELAY="$delay" ATFM_PANEL_HEIGHT=640 "$@" "$APP" > "$D/log-$name.txt" 2>&1 &)
}
shot clipboard 9; sleep 2
for t in "https://www.youtube.com/watch?v=aqz-KE-bpKQ" "회의 15:00 회의실 B로 변경" "let total = items.reduce(0) { \$0 + \$1.price }" "ATFM: Additional Things For Mac" "010-1234-5678"; do printf '%s' "$t" | pbcopy; sleep 0.9; done
printf '%s' "https://www.youtube.com/watch?v=aqz-KE-bpKQ" | pbcopy; sleep 8
for tab in checklist notes dates awake system network actions tools autoscroll convert ai settings; do
  d=4; [[ $tab == system || $tab == network ]] && d=7
  if [[ $tab == actions ]]; then shot "$tab" 7 ATFM_DEBUG_CLEANUP_SCAN=1; sleep 10; continue; fi
  shot "$tab" "$d"; sleep $((d + 3))
done
SHOT_NAME=dictionary shot dictionary 4 ATFM_DEBUG_DICT="periodic|Fe"; sleep 7
SHOT_NAME=dictionary-korean shot dictionary 4 ATFM_DEBUG_DICT="korean|사과"; sleep 7
unset SHOT_NAME
# player + floating mini player with a made-up track
mini_enabled="$(defaults read com.geonhee.atfm miniPlayerEnabled 2>/dev/null || echo unset)"
defaults write com.geonhee.atfm miniPlayerEnabled -bool true
shot player 4 ATFM_DEBUG_NOWPLAYING_SAMPLE=1 ATFM_SNAPSHOT_MINI="$OUT/miniplayer.png"; sleep 8
if [[ $mini_enabled == unset ]]; then defaults delete com.geonhee.atfm miniPlayerEnabled; else defaults write com.geonhee.atfm miniPlayerEnabled -bool "$mini_enabled"; fi
pkill -x ATFM 2>/dev/null; sleep 0.4
for mode in hud-text hud-color; do rm -f "$OUT/$mode.png"; (env ATFM_DEBUG_DATA_DIR="$D" ATFM_DEBUG_TOOLS=$mode ATFM_SNAPSHOT_HUD="$OUT/$mode.png" ATFM_SNAPSHOT_DELAY=0.5 "$APP" > /dev/null 2>&1 &); sleep 3; pkill -x ATFM; sleep 0.4; done
printf '%s' "$saved_clip" | pbcopy
python3 - "$OUT" <<'PY'
import sys,os
from PIL import Image
out=sys.argv[1]
for name in sorted(os.listdir(out)):
    if not name.endswith(".png") or name.startswith("hud") or name=="miniplayer.png": continue
    p=os.path.join(out,name); im=Image.open(p).convert("RGBA"); w,h=im.size
    if h==1280: im=im.crop((0,22,w,h)); im.save(p)   # drop the 11pt bubble arrow strip
    print(name, im.size)
PY
rm -rf "$D"; open build/ATFM.app
