#!/usr/bin/env python3
"""
sync_github_to_s3.py
──────────────────────────────────────────────────────────────────
GitHub repo (judy-kimsohui/yamyam-data) 의 .mp4 파일 목록을 확인하고,
아직 S3 에 업로드되지 않은 신규 영상만 다운로드 → S3 → DB INSERT 합니다.

슬롯 할당 규칙:
  · 오늘 날짜부터 과거 방향으로 빈 슬롯을 채움
  · 사용자 ID 오름차순 (EXCLUDE_USER_IDS 에 속한 사용자는 제외)
  · 팀 멤버십은 DB 에서 실시간 조회
  · 이미 채워진 (user_id, team_id, meal_type, meal_date) 는 건너뜀

사용법:
  python3 scripts/sync_github_to_s3.py              # 실제 실행
  python3 scripts/sync_github_to_s3.py --dry-run    # 미리보기 (변경 없음)

필요 환경변수:
  AWS_ACCESS_KEY_ID      (필수)
  AWS_SECRET_ACCESS_KEY  (필수)
  EXCLUDE_USER_IDS       (기본: "5"  — 나 자신 user_id, 쉼표 구분 복수 가능)
  S3_BUCKET              (기본: yamyam-videos-bucket)
  S3_REGION              (기본: ap-northeast-2)
  DB_CONTAINER           (기본: app-mysql-1  — docker exec 대상 컨테이너)
  DB_USER                (기본: root)
  DB_PASSWORD            (기본: ssafy)
  DB_NAME                (기본: yamyamdb)

동기화 상태는 scripts/.synced_videos.json 에 저장됩니다.
  pip install boto3
──────────────────────────────────────────────────────────────────
"""

import json
import os
import random
import subprocess
import sys
import tempfile
import urllib.request
import uuid
from datetime import date, timedelta
from pathlib import Path

# ── MZ 식단 소개글 풀 ──────────────────────────────────────────────
DESCRIPTIONS = [
    "야미야미", "헤비식사", "오늘도영양", "클린밀", "득근영양",
    "탄단지완벽", "단짠단짠", "밥심충전", "든든한끼", "굿밀",
    "식단관리중", "밀프렙완성", "깔끔한맛", "맛집인정", "건강한끼",
    "단백질충전", "탄수러버", "저칼로리", "영양가득", "맛보장",
    "먹방각", "꿀조합", "건강픽", "식욕자극", "덮밥러버",
    "국밥사랑", "든든함주의", "밀프렙", "탄단지", "깔끔식단",
    "영양밸런스", "먹스타그램", "오늘도맛있다", "건강식", "다이어트중",
    "굿밥", "점심각", "저녁루틴", "아침식사", "식단성공",
    "꿀꺽", "맛있는삶", "오늘도화이팅", "깔끔완성", "오늘의식단",
    "다이어트식단", "배부름주의", "탄단지충전", "뇨끼러버", "꼭꼭씹기",
    "대충차린상", "혼밥각", "홈메이드", "간편식단", "건강챙기기",
    "식단기록", "오늘뭐먹지", "맛있으면0칼", "작지만든든", "과식주의보",
]

# ── 설정 ─────────────────────────────────────────────────────────
GITHUB_OWNER  = "judy-kimsohui"
GITHUB_REPO   = "yamyam-data"
GITHUB_BRANCH = "main"
RAW_BASE_URL  = f"https://raw.githubusercontent.com/{GITHUB_OWNER}/{GITHUB_REPO}/{GITHUB_BRANCH}"

S3_BUCKET    = os.environ.get("S3_BUCKET",    "yamyam-videos-bucket")
S3_REGION    = os.environ.get("S3_REGION",    "ap-northeast-2")
DB_CONTAINER = os.environ.get("DB_CONTAINER", "app-mysql-1")
DB_USER      = os.environ.get("DB_USER",      "root")
DB_PASS      = os.environ.get("DB_PASSWORD",  "ssafy")
DB_NAME      = os.environ.get("DB_NAME",      "yamyamdb")
SPRING_URL   = os.environ.get("SPRING_URL",   "http://localhost:8080")

# 슬롯 할당에서 제외할 user_id  (나 = ssafy5 → id=5)
EXCLUDE_USER_IDS: set[int] = {
    int(x.strip())
    for x in os.environ.get("EXCLUDE_USER_IDS", "5").split(",")
    if x.strip()
}

SYNC_STATE = Path(__file__).parent / ".synced_videos.json"


# ── 상태 파일 ──────────────────────────────────────────────────────
def load_sync_state() -> dict:
    if SYNC_STATE.exists():
        return json.loads(SYNC_STATE.read_text(encoding="utf-8"))
    return {"synced": []}


def save_sync_state(state: dict):
    SYNC_STATE.write_text(json.dumps(state, indent=2, ensure_ascii=False), encoding="utf-8")


# ── DB 헬퍼 (docker exec 경유) ────────────────────────────────────
def run_mysql(sql: str) -> str:
    result = subprocess.run(
        ["docker", "exec", DB_CONTAINER,
         "mysql", "--default-character-set=utf8mb4",
         f"-u{DB_USER}", f"-p{DB_PASS}",
         "--batch", "--skip-column-names", DB_NAME, "-e", sql],
        capture_output=True, text=True, encoding="utf-8",
    )
    return result.stdout


def fetch_db_used_slots() -> set:
    """DB 에 이미 존재하는 (user_id, team_id, meal_type, meal_date) 세트"""
    rows = run_mysql("SELECT user_id, team_id, meal_type, meal_date FROM VIDEOS;")
    used = set()
    for line in rows.strip().split("\n"):
        parts = line.split("\t")
        if len(parts) == 4:
            uid, tid, mtype, mdate = parts
            used.add((int(uid), int(tid), mtype, mdate))
    return used


def fetch_team_memberships() -> dict[int, list[int]]:
    """DB 에서 user_id → [team_id, ...] 멤버십 동적 조회"""
    rows = run_mysql("SELECT user_id, team_id FROM TEAM_MEMBERS ORDER BY user_id, team_id;")
    memberships: dict[int, list[int]] = {}
    for line in rows.strip().split("\n"):
        parts = line.split("\t")
        if len(parts) == 2:
            uid, tid = int(parts[0]), int(parts[1])
            memberships.setdefault(uid, []).append(tid)
    return memberships


# ── GitHub ────────────────────────────────────────────────────────
def fetch_github_videos() -> list[str]:
    """GitHub API / gh CLI 로 .mp4 파일 목록 반환 (알파벳순)"""
    try:
        result = subprocess.run(
            ["gh", "api",
             f"repos/{GITHUB_OWNER}/{GITHUB_REPO}/git/trees/{GITHUB_BRANCH}",
             "--jq", '.tree[] | select(.path | endswith(".mp4")) | .path'],
            capture_output=True, text=True, check=True,
        )
        files = [f.strip() for f in result.stdout.strip().split("\n") if f.strip()]
        if files:
            return sorted(files)
    except Exception:
        pass

    # gh CLI 없을 때 urllib fallback (public repo)
    api_url = (
        f"https://api.github.com/repos/{GITHUB_OWNER}/{GITHUB_REPO}"
        f"/git/trees/{GITHUB_BRANCH}"
    )
    req = urllib.request.Request(api_url, headers={"User-Agent": "yamyam-sync"})
    with urllib.request.urlopen(req) as resp:
        data = json.loads(resp.read())
    return sorted(item["path"] for item in data["tree"] if item["path"].endswith(".mp4"))


# ── 슬롯 생성 ──────────────────────────────────────────────────────
def generate_available_slots(
    db_used: set,
    memberships: dict[int, list[int]],
) -> list[tuple]:
    """오늘 → 과거 방향, 사용자 ID 오름차순으로 빈 슬롯 목록 반환.
    EXCLUDE_USER_IDS 에 속한 사용자는 제외.
    최대 60일 과거까지 탐색."""
    meal_types = ("BREAKFAST", "LUNCH", "DINNER")
    slots: list[tuple] = []
    for days_ago in range(0, 60):
        d = date.today() - timedelta(days=days_ago)
        for user_id in sorted(memberships.keys()):
            if user_id in EXCLUDE_USER_IDS:
                continue
            for team_id in sorted(memberships[user_id]):
                for meal_type in meal_types:
                    key = (user_id, team_id, meal_type, d.isoformat())
                    if key not in db_used:
                        slots.append((user_id, team_id, meal_type, d))
    return slots


# ── S3 업로드 ─────────────────────────────────────────────────────
def upload_to_s3(local_path: str, s3_key: str, dry_run: bool) -> str:
    if dry_run:
        print(f"  [dry-run] S3 업로드 건너뜀: {s3_key}")
        return s3_key

    try:
        import boto3
    except ImportError:
        print("오류: boto3 가 없습니다.  pip install boto3", file=sys.stderr)
        sys.exit(1)

    s3 = boto3.client(
        "s3",
        region_name=S3_REGION,
        aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID"),
        aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY"),
    )
    s3.upload_file(local_path, S3_BUCKET, s3_key)
    return s3_key  # video_url = S3 key (leading slash 없음)


# ── DB INSERT ─────────────────────────────────────────────────────
def insert_video_to_db(
    user_id: int, team_id: int, meal_type: str,
    meal_date: date, video_url: str, description: str,
    dry_run: bool,
) -> int | None:
    sql = (
        f"INSERT INTO VIDEOS (user_id, team_id, meal_type, meal_date, video_url, description) "
        f"VALUES ({user_id}, {team_id}, '{meal_type}', '{meal_date}', "
        f"'{video_url}', '{description}');\n"
        f"SELECT LAST_INSERT_ID();"
    )
    if dry_run:
        print(f"  [dry-run] DB INSERT 건너뜀")
        return None

    result = subprocess.run(
        ["docker", "exec", "-i", DB_CONTAINER,
         "mysql", "--default-character-set=utf8mb4", "--batch", "--skip-column-names",
         f"-u{DB_USER}", f"-p{DB_PASS}", DB_NAME],
        input=sql, text=True, encoding="utf-8", capture_output=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"DB INSERT 실패: {result.stderr}")

    for line in result.stdout.strip().split("\n"):
        if line.strip().isdigit():
            return int(line.strip())
    return None


def trigger_analysis(video_id: int) -> None:
    url = f"{SPRING_URL}/api/videos/{video_id}/analyze"
    try:
        req = urllib.request.Request(url, method="POST", data=b"")
        with urllib.request.urlopen(req, timeout=10) as resp:
            if resp.status == 202:
                print(f"  AI 분석 시작 (video_id={video_id})")
            # 204 = 이미 분석됨, 무시
    except Exception as e:
        print(f"  ⚠️ AI 분석 트리거 실패 (video_id={video_id}): {e}")


# ── 메인 ──────────────────────────────────────────────────────────
def main():
    dry_run = "--dry-run" in sys.argv
    if dry_run:
        print("[dry-run 모드] 실제 업로드/DB 변경 없음\n")

    print(f"제외 user_id: {sorted(EXCLUDE_USER_IDS)}")

    # 1) GitHub 파일 목록
    print("GitHub 영상 목록 조회 중...")
    github_videos = fetch_github_videos()
    print(f"GitHub: {len(github_videos)}개 .mp4")

    # 2) 이미 처리된 파일 제외
    state = load_sync_state()
    synced_paths = {entry["github_path"] for entry in state["synced"]}
    new_videos = [v for v in github_videos if v not in synced_paths]

    if not new_videos:
        print("신규 영상 없음. 완료.")
        return

    print(f"\n신규 영상 {len(new_videos)}개:")
    for v in new_videos:
        print(f"  {v}")

    # 3) DB 슬롯 분석
    print("\nDB 슬롯 분석 중...")
    db_used = fetch_db_used_slots()
    memberships = fetch_team_memberships()
    available = generate_available_slots(db_used, memberships)

    print(f"가용 슬롯: {len(available)}개 (오늘 기준 최대 60일)\n")

    if not available:
        print("⚠️  할당 가능한 빈 슬롯 없음.")
        return

    slot_iter = iter(available)

    for github_path in new_videos:
        try:
            user_id, team_id, meal_type, meal_date = next(slot_iter)
        except StopIteration:
            print("⚠️  빈 슬롯 소진. 남은 영상 건너뜀.")
            break

        ext = Path(github_path).suffix or ".mp4"
        s3_key = f"videos/{uuid.uuid4()}{ext}"

        print(f"▶ {github_path}")
        print(f"  S3 : {s3_key}")
        print(f"  DB : user={user_id}, team={team_id}, {meal_type}, {meal_date}")

        download_url = f"{RAW_BASE_URL}/{urllib.request.quote(github_path)}"
        with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as tmp:
            tmp_path = tmp.name

        try:
            if not dry_run:
                urllib.request.urlretrieve(download_url, tmp_path)

            video_url = upload_to_s3(tmp_path, s3_key, dry_run)
            description = random.choice(DESCRIPTIONS)
            video_id = insert_video_to_db(
                user_id, team_id, meal_type, meal_date,
                video_url, description, dry_run,
            )
            if video_id:
                trigger_analysis(video_id)

            # 메모리 내 used set 갱신 (같은 슬롯 중복 방지)
            db_used.add((user_id, team_id, meal_type, meal_date.isoformat()))

            state["synced"].append({
                "github_path": github_path,
                "s3_key": s3_key,
                "video_url": video_url,
                "user_id": user_id,
                "team_id": team_id,
                "meal_type": meal_type,
                "meal_date": meal_date.isoformat(),
            })
            if not dry_run:
                save_sync_state(state)

            print("  완료\n")

        finally:
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)

    total = len(new_videos)
    print(f"동기화 완료 — 신규 {total}개 처리됨.")
    if dry_run:
        print("(dry-run: 실제 변경 없음)")


if __name__ == "__main__":
    main()
