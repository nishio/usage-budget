#!/usr/bin/env bash
# usage-budget: Claude の使用量 (5時間枠 / 週次枠) から「いま何%まで使ってよいか」を時間連動で出す。
# 実行判断はしない。数値と GO / CAUTION / BLOCK を返すだけ。
#
# 取得元: Claude Code の OAuth usage エンドポイント (/usage と同じデータ源・非公開 API なので形が変わりうる)。
#
# 【判定モデル: 時間連動】
#   リセットする枠は「使わなければ失われる」= 温存価値はリセットまでの時間とともにゼロへ近づく。
#   ・5h 枠  = 残量の SAFETY を平坦に使う (毎5hリセット・単発バーストなので温存に意味がない)。
#   ・週次枠 = 「均等ペース」模型。週の経過割合だけ残量を使ってよい (= 残り週割合を温存)。
#              使える% = 残 × (1 − リセットまで時間/窓) × PACE_AGGR
#   作業単位あたりのコスト (UNIT_COST_5H / UNIT_COST_WEEK) を渡すと、何単位回せるかも出す。
#
# 使い方:
#   budget.sh            人間向け表示
#   budget.sh --json     機械向け JSON (スクリプトから使う)
#   UNIT_COST_5H=2.7 UNIT_COST_WEEK=0.15 MAX_UNITS=32 budget.sh   作業単位で上限を出す
set -euo pipefail

MODE=${1:-}
CRED=${CRED:-$HOME/.claude/.credentials.json}
TOKEN=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['claudeAiOauth']['accessToken'])" "$CRED")

RAW=$(curl -s -m 20 https://api.anthropic.com/api/oauth/usage \
  -H "Authorization: Bearer $TOKEN" \
  -H "anthropic-beta: oauth-2025-04-20")

RAW="$RAW" MODE="$MODE" python3 <<'PY'
import json, os, sys, datetime
raw = os.environ.get("RAW", "").strip()
if not raw:
    print("ERROR: usage エンドポイントが空応答。トークン失効/ネットワークを確認。", file=sys.stderr)
    sys.exit(2)
d = json.loads(raw)
if "five_hour" not in d and "seven_day" not in d:
    print(f"ERROR: 想定外の応答: {raw[:300]}", file=sys.stderr)
    sys.exit(2)

env = os.environ.get
S_SAFETY    = float(env("SAFETY", "0.75"))          # 5h 残量の何割まで使うか
PACE_AGGR   = float(env("PACE_AGGR", "1.0"))        # 週次の前倒し度 (>1=均等ペースより早く使う)
RESERVE_MIN = float(env("RESERVE_MIN", "2"))        # どの枠も最低これだけ%は残す
WEEKLY_WIN  = float(env("WEEKLY_WINDOW_H", "168"))  # 週次枠の窓 (時間)
MIN_5H      = float(env("MIN_5H", "5"))             # GO に必要な 5h の使える% (単位指定なし時)
MIN_WEEK    = float(env("MIN_WEEK", "1"))           # GO に必要な週次の使える% (単位指定なし時)
U5          = float(env("UNIT_COST_5H", "0"))       # 1単位あたり 5h pt (0=単位計算しない)
UW          = float(env("UNIT_COST_WEEK", "0"))     # 1単位あたり 週次 pt
MAX_UNITS   = int(env("MAX_UNITS", "0"))            # 単位数の上限 (0=上限なし)
MIN_UNITS   = int(env("MIN_UNITS", "1"))            # GO に必要な最小単位数

now = datetime.datetime.now(datetime.timezone.utc)
def hrs(iso):
    if not iso: return None
    try:
        return max(0.0, (datetime.datetime.fromisoformat(iso.replace("Z", "+00:00")) - now).total_seconds() / 3600.0)
    except Exception:
        return None

fh = d.get("five_hour") or {}
sd = d.get("seven_day") or {}
limits = {l.get("kind"): l for l in d.get("limits", []) or []}
wa = limits.get("weekly_all", {})

fh_pct = fh.get("utilization")
wk_pct = wa.get("percent", sd.get("utilization"))
wk_sev = wa.get("severity", "normal")
fh_reset = fh.get("resets_at")
wk_reset = wa.get("resets_at") or sd.get("resets_at")
fh_h, wk_h = hrs(fh_reset), hrs(wk_reset)

s_head = (100 - fh_pct) if fh_pct is not None else 0
w_head = (100 - wk_pct) if wk_pct is not None else 0

def spendable_flat(head, frac):
    return max(0.0, min(head - RESERVE_MIN, head * frac)) if head > RESERVE_MIN else 0.0

def spendable_paced(head, hours_left, window, aggr):
    if head <= RESERVE_MIN:
        return 0.0
    frac_left = 0.0 if hours_left is None else max(0.0, min(1.0, hours_left / window))
    return max(0.0, min(head - RESERVE_MIN, head * (1.0 - frac_left) * aggr))

s_spend = spendable_flat(s_head, S_SAFETY)
w_spend = spendable_paced(w_head, wk_h, WEEKLY_WIN, PACE_AGGR)

HARD_SEV = {"exceeded", "critical", "blocked", "hard"}
hard = wk_sev in HARD_SEV

units = None
if U5 > 0 or UW > 0:
    big = 10**9
    s_cap = int(s_spend / U5) if U5 > 0 else big
    w_cap = int(w_spend / UW) if UW > 0 else big
    units = min(s_cap, w_cap)
    if MAX_UNITS > 0:
        units = min(units, MAX_UNITS)
    binding = "5h" if s_cap <= w_cap else "週次"
    if hard:
        units = 0
    verdict = "GO" if units >= MIN_UNITS else ("CAUTION" if units >= 1 else "BLOCK")
else:
    binding = "5h" if s_spend / MIN_5H <= w_spend / MIN_WEEK else "週次"
    if hard or s_spend <= 0 or w_spend <= 0:
        verdict = "BLOCK"
    elif s_spend >= MIN_5H and w_spend >= MIN_WEEK:
        verdict = "GO"
    else:
        verdict = "CAUTION"
if hard:
    binding = "週次(頭打ち)"

out = {
    "verdict": verdict, "binding": binding,
    "five_hour": {"used_pct": fh_pct, "remaining_pct": s_head, "spendable_pct": round(s_spend, 1),
                  "resets_at": fh_reset, "hours_to_reset": None if fh_h is None else round(fh_h, 2)},
    "weekly": {"used_pct": wk_pct, "remaining_pct": w_head, "spendable_pct": round(w_spend, 1),
               "severity": wk_sev, "resets_at": wk_reset, "hours_to_reset": None if wk_h is None else round(wk_h, 2)},
    "units": units,
}

if os.environ.get("MODE") == "--json":
    print(json.dumps(out, ensure_ascii=False))
    sys.exit(0)

def fmt_h(h):
    if h is None: return "不明"
    return f"{h * 60:.0f}分後" if h < 1 else f"{h:.1f}時間後"

print("=== usage-budget: 使用量判定 (時間連動モデル) ===")
print(f"  5時間枠: 使用{fh_pct}%  残{s_head}%  リセット {fmt_h(fh_h)}")
print(f"  週次枠 : 使用{wk_pct}%  残{w_head}%  severity={wk_sev}  リセット {fmt_h(wk_h)}")
if hard:
    print(f"  ※週次 severity={wk_sev} = 実際の頭打ち")
print()
print(f"  使える枠: 5h={s_spend:.0f}% (残×{S_SAFETY:.2f}) / 週次={w_spend:.0f}% (均等ペース: 残り週割合を温存)")
if wk_h is not None and wk_h < 24 and w_head > 0 and not hard:
    print(f"  注: 週次は {fmt_h(wk_h)} にリセット。消える枠は温存価値が低い (使わなければ失われる)。")
if units is not None:
    print(f"  作業単位: 5h {U5}pt/単位・週次 {UW}pt/単位 → 回せる {units} 単位 (律速={binding})")
print()
print(f"VERDICT={verdict}")
print(f"SPEND_5H={s_spend:.1f}")
print(f"SPEND_WEEK={w_spend:.1f}")
if units is not None:
    print(f"UNITS={units}")
print(f"BINDING={binding}")
PY
