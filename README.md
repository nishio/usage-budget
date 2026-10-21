# usage-budget

Claude Code の使用量 (5時間枠 / 週次枠) を見て、**リセットまでの時間を織り込んで「いま何%まで使ってよいか」** を出す Claude Code skill。
重い作業 (並列 agent・Workflow・大量バッチ) を始める前に、どの深さで回すかを決めるために使う。判定を出すだけで、何も起動しない。

## 考え方

リセットされる枠は**使わなければ失われる**。残量 % だけで「温存しよう」と判断すると、もうすぐ消える枠を抱えたまま終わる。そこで枠ごとに「使ってよい量」を時間連動で決める。

| 枠 | 使ってよい量 | 理由 |
|---|---|---|
| 5時間枠 | 残量 × `SAFETY` (既定 0.75) | 5時間ごとに必ずリセットされるので温存に意味がない |
| 週次枠 | 残量 × (1 − リセットまでの時間 / 168h) | 均等ペース。週の序盤は温存し、リセット間近ならほぼ全部使う |

週次の severity が頭打ち (`exceeded` 等) を示すときだけ BLOCK。`warning` は情報として表示するだけ。

## インストール

```bash
gh repo clone nishio/usage-budget ~/.claude/skills/usage-budget
```

`~/.claude/skills/` に置くと全プロジェクトで有効になる。Claude Code に「使用量見て」「今どれだけ使っていい?」と頼むと呼ばれる。

### 前提

- Claude Code に **OAuth でログイン**していること (`~/.claude/.credentials.json` を読む)。API キー利用の環境では動かない。
- `bash` / `curl` / `python3`

## 使い方

```bash
bash ~/.claude/skills/usage-budget/budget.sh          # 人間向け表示
bash ~/.claude/skills/usage-budget/budget.sh --json   # スクリプト向け JSON
```

出力例:

```
=== usage-budget: 使用量判定 (時間連動モデル) ===
  5時間枠: 使用25.0%  残75.0%  リセット 4.1時間後
  週次枠 : 使用21%  残79%  severity=normal  リセット 159.1時間後

  使える枠: 5h=56% (残×0.75) / 週次=4% (均等ペース: 残り週割合を温存)

VERDICT=GO
SPEND_5H=56.2
SPEND_WEEK=4.2
BINDING=週次
```

### 作業単位で「何回回せるか」を出す

1単位 (agent 1本・バッチ1回など) あたりの消費 pt を渡すと、回せる単位数を出す:

```bash
UNIT_COST_5H=2.7 UNIT_COST_WEEK=0.15 MAX_UNITS=32 bash ~/.claude/skills/usage-budget/budget.sh
# → UNITS=20  BINDING=5h
```

係数はプロジェクトごとに違うので実測する。1回走らせ、前後で `budget.sh --json` を叩いて使用率の差分を見ればよい。

### 調整用の環境変数

| 変数 | 既定 | 意味 |
|---|---|---|
| `SAFETY` | 0.75 | 5h 残量の何割まで使うか |
| `PACE_AGGR` | 1.0 | 週次を均等ペースより前倒しする度合い (>1 で積極的) |
| `RESERVE_MIN` | 2 | どの枠も最低これだけ % は残す |
| `WEEKLY_WINDOW_H` | 168 | 週次枠の窓 (時間) |
| `MIN_5H` / `MIN_WEEK` | 5 / 1 | 単位指定なしのとき GO に必要な使える % |
| `UNIT_COST_5H` / `UNIT_COST_WEEK` | 0 | 1単位あたりの消費 pt (0 = 単位計算しない) |
| `MAX_UNITS` | 0 | 単位数の上限 (0 = 上限なし) |
| `MIN_UNITS` | 1 | 単位指定ありのとき GO に必要な単位数 |
| `CRED` | `~/.claude/.credentials.json` | OAuth 資格情報の場所 |

## 判定

| VERDICT | 意味 |
|---|---|
| `GO` | 両方の枠に十分な余裕がある (単位指定時は `MIN_UNITS` 以上回せる) |
| `CAUTION` | 少しなら使えるが、GO の閾値に届かない |
| `BLOCK` | 使える量がない、または週次が頭打ち |

## 注意

- 取得元は Claude Code の OAuth usage エンドポイント (`/usage` と同じデータ源) で、**非公開 API**。応答の形が変わるとエラーで止まる。
- 資格情報はローカルで読むだけで、Anthropic の API 以外には送らない。
