#!/usr/bin/env bash
# gw の POST_CREATE_CMD 用: 作成した worktree を herdr workspace として追加する
# - session 名 = メインリポジトリのディレクトリ名
# - session が未起動なら headless server として自動起動
# - 同じ label の workspace が既にあれば再利用し、claude が起動しているペインを探す
#   (見つからなければそのペインで claude を再起動する)
#
# gw から渡される環境変数:
#   GW_WORKTREE_PATH    worktree の絶対パス (必須)
#   GW_MAIN_REPO_PATH   メインリポジトリの絶対パス (必須)
#   GW_BRANCH_NAME      ブランチ名 (--detach 時は空)
#   GW_TARGET_FILE      -f 指定時のファイル絶対パス
#   GW_POST_SCRIPT_ARGS gw -p/--post-script-args で渡された、スペース区切りのトークン列
#                         skip         ... herdr 連携を一切行わず即終了する
#                         no-focus     ... workspace の作成/再利用時に画面を奪わない
#                         format=json  ... 結果を JSON で stdout に出力する
#                         hdr-gw-child ... 起動する claude に HDR_GW_CHILD=1 を付与する
set -euo pipefail

no_focus=""
format_json=""
hdr_gw_child=""
# shellcheck disable=SC2086 # 意図的な word splitting でスペース区切りトークンへ分割する
for token in ${GW_POST_SCRIPT_ARGS:-}; do
  case "$token" in
    skip)
      exit 0
      ;;
    no-focus)
      no_focus=1
      ;;
    format=json)
      format_json=1
      ;;
    hdr-gw-child)
      hdr_gw_child=1
      ;;
    *)
      echo "post-create: unknown GW_POST_SCRIPT_ARGS token: $token" >&2
      exit 1
      ;;
  esac
done

claude_launch_cmd="claude"
if [ -n "$hdr_gw_child" ]; then
  claude_launch_cmd="HDR_GW_CHILD=1 claude"
fi

command -v jq > /dev/null || {
  echo "post-create: jq command not found in PATH" >&2
  exit 1
}

: "${GW_WORKTREE_PATH:?GW_WORKTREE_PATH is required}"
: "${GW_MAIN_REPO_PATH:?GW_MAIN_REPO_PATH is required}"

repo_name="$(basename "$GW_MAIN_REPO_PATH")"
branch="${GW_BRANCH_NAME:-$(basename "$GW_WORKTREE_PATH")}"
label="$repo_name:$branch"

focus_flag="--focus"
if [ -n "$no_focus" ]; then
  focus_flag="--no-focus"
fi

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

# workspace 内で claude agent として self-report しているペインを探す
find_claude_pane() {
  local ws_id="$1"
  herdr --session "$session" pane list --workspace "$ws_id" 2> /dev/null \
    | jq -r '.result.panes[]? | select(.agent == "claude") | .pane_id' \
    | head -n 1
}

# workspace の先頭ペイン (claude 起動先の既定候補) を取得する
first_pane_of_workspace() {
  local ws_id="$1"
  herdr --session "$session" pane list --workspace "$ws_id" 2> /dev/null \
    | jq -r '.result.panes[0].pane_id // empty'
}

existing_ws=$(
  herdr --session "$session" workspace list 2> /dev/null \
    | jq -r --arg label "$label" \
      '.result.workspaces[]? | select(.label == $label) | .workspace_id' \
    | head -n 1
)

reused=false
hunk_pane=""

if [ -n "$existing_ws" ]; then
  reused=true
  ws_id="$existing_ws"
  if [ -z "$no_focus" ]; then
    herdr --session "$session" workspace focus "$ws_id" > /dev/null 2>&1
  fi

  claude_pane=$(find_claude_pane "$ws_id")
  if [ -z "$claude_pane" ]; then
    # 既存 workspace に claude を報告しているペインが見つからない
    # (claude が終了している等) 場合、先頭ペインで claude を起動し直す
    claude_pane=$(first_pane_of_workspace "$ws_id")
    if [ -z "$claude_pane" ]; then
      echo "post-create: existing workspace has no panes to launch claude in (workspace: $ws_id, label: $label)" >&2
      exit 1
    fi
    herdr --session "$session" pane send-text "$claude_pane" "$claude_launch_cmd"$'\n' > /dev/null 2>&1 || true
  fi
else
  ws_json=$(herdr --session "$session" workspace create \
    --cwd "$GW_WORKTREE_PATH" \
    --label "$label" \
    "$focus_flag" 2> /dev/null)
  ws_id=$(echo "$ws_json" | jq -r '.result.workspace.workspace_id // empty')
  if [ -z "$ws_id" ]; then
    echo "post-create: failed to create herdr workspace (label: $label, cwd: $GW_WORKTREE_PATH)" >&2
    exit 1
  fi

  claude_pane=$(first_pane_of_workspace "$ws_id")
  if [ -z "$claude_pane" ]; then
    echo "post-create: failed to resolve root pane of new workspace (workspace: $ws_id, label: $label)" >&2
    exit 1
  fi

  split_json=$(herdr --session "$session" pane split "$claude_pane" \
    --direction right \
    --cwd "$GW_WORKTREE_PATH" \
    --no-focus 2> /dev/null)
  hunk_pane=$(echo "$split_json" | jq -r '.result.pane.pane_id // empty')

  herdr --session "$session" pane send-text "$claude_pane" "$claude_launch_cmd"$'\n' > /dev/null 2>&1 || true
  if [ -n "$hunk_pane" ]; then
    herdr --session "$session" pane send-text "$hunk_pane" $'hunk diff --watch\n' > /dev/null 2>&1 || true
  fi
fi

if [ -n "$format_json" ]; then
  tab_id=$(herdr --session "$session" pane get "$claude_pane" 2> /dev/null \
    | jq -r '.result.pane.tab_id // empty')
  jq -cn \
    --arg workspace_id "$ws_id" \
    --arg tab_id "$tab_id" \
    --arg claude_pane_id "$claude_pane" \
    --arg hunk_pane_id "$hunk_pane" \
    --argjson reused "$reused" \
    '{workspace_id: $workspace_id, tab_id: $tab_id, claude_pane_id: $claude_pane_id}
     + (if $hunk_pane_id != "" then {hunk_pane_id: $hunk_pane_id} else {} end)
     + {reused: $reused}'
fi
