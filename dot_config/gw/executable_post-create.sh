#!/usr/bin/env bash
# gw の POST_CREATE_CMD 用: 作成した worktree を herdr workspace として追加する
# - session 名 = メインリポジトリのディレクトリ名
# - session が未起動なら headless server として自動起動
# - 同じ label の workspace が既にあれば focus のみ
#
# gw から渡される環境変数:
#   GW_WORKTREE_PATH   worktree の絶対パス (必須)
#   GW_MAIN_REPO_PATH  メインリポジトリの絶対パス (必須)
#   GW_BRANCH_NAME     ブランチ名 (--detach 時は空)
#   GW_TARGET_FILE     -f 指定時のファイル絶対パス
set -euo pipefail

command -v jq > /dev/null || {
  echo "post-create: jq command not found in PATH" >&2
  exit 1
}

: "${GW_WORKTREE_PATH:?GW_WORKTREE_PATH is required}"
: "${GW_MAIN_REPO_PATH:?GW_MAIN_REPO_PATH is required}"

repo_name="$(basename "$GW_MAIN_REPO_PATH")"
branch="${GW_BRANCH_NAME:-$(basename "$GW_WORKTREE_PATH")}"
label="$repo_name:$branch"

# herdr セッション内なら現在の session を、そうでなければ repo 名の session を対象にする
if [ -n "${HERDR_SOCKET_PATH:-}" ]; then
  # socket path から session 名を導出
  #   ~/.config/herdr/herdr.sock                  → default
  #   ~/.config/herdr/sessions/<name>/herdr.sock  → <name>
  sock_dir="$(dirname "$HERDR_SOCKET_PATH")"
  parent_dir="$(dirname "$sock_dir")"
  if [ "$(basename "$parent_dir")" = "sessions" ]; then
    session="$(basename "$sock_dir")"
  else
    session="default"
  fi
else
  session="$repo_name"
fi

# session が running でなければ headless server として起動
running=$(herdr session list --json 2> /dev/null \
  | jq -r --arg name "$session" \
    '.sessions[]? | select(.name == $name) | .running')

if [ "$running" != "true" ]; then
  herdr --session "$session" server > /dev/null 2>&1 &
  # `herdr status server` は not_running でも exit 0 を返すため、
  # exit code ではなく JSON の .running フィールドで判定する
  server_ready=""
  for _ in $(seq 1 30); do
    if [ "$(herdr --session "$session" status server --json 2> /dev/null \
      | jq -r '.running // false')" = "true" ]; then
      server_ready=1
      break
    fi
    sleep 0.1
  done
  if [ -z "$server_ready" ]; then
    echo "post-create: herdr server (session=$session) failed to start" >&2
    exit 1
  fi
fi

existing_ws=$(
  herdr --session "$session" workspace list 2> /dev/null \
    | jq -r --arg label "$label" \
      '.result.workspaces[]? | select(.label == $label) | .workspace_id' \
    | head -n 1
)

if [ -n "$existing_ws" ]; then
  herdr --session "$session" workspace focus "$existing_ws" > /dev/null 2>&1
else
  ws_json=$(herdr --session "$session" workspace create \
    --cwd "$GW_WORKTREE_PATH" \
    --label "$label" \
    --focus 2> /dev/null)
  ws_id=$(echo "$ws_json" | jq -r '.result.workspace.workspace_id // empty')
  if [ -n "$ws_id" ]; then
    left_pane=$(herdr --session "$session" pane list --workspace "$ws_id" 2> /dev/null \
      | jq -r '.result.panes[0].pane_id // empty')
    if [ -n "$left_pane" ]; then
      split_json=$(herdr --session "$session" pane split "$left_pane" \
        --direction right \
        --cwd "$GW_WORKTREE_PATH" \
        --no-focus 2> /dev/null)
      right_pane=$(echo "$split_json" | jq -r '.result.pane.pane_id // empty')
      herdr --session "$session" pane send-text "$left_pane" $'claude\n' > /dev/null 2>&1 || true
      if [ -n "$right_pane" ]; then
        herdr --session "$session" pane send-text "$right_pane" $'hunk diff --watch\n' > /dev/null 2>&1 || true
      fi
    fi
  fi
fi
