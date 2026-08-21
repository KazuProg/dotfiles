#!/usr/bin/env bash
# gw の POST_CREATE_CMD 用: 作成した worktree を herdr workspace として追加する
# - session 名 = メインリポジトリのディレクトリ名
#   (英数字と ._- 以外は - に置換し、連続する - は 1 つに畳む)
#   例外: herdr セッション内から呼ばれた場合は、そのセッションの名前をそのまま使う
# - session が未起動なら headless server として自動起動
# - 同じ worktree が既に開かれていれば再利用し、claude が起動しているペインを探す
#   (見つからなければ root pane で claude を起動し直す)
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

command -v herdr > /dev/null || {
  echo "post-create: herdr command not found in PATH" >&2
  exit 1
}

command -v jq > /dev/null || {
  echo "post-create: jq command not found in PATH" >&2
  exit 1
}

: "${GW_WORKTREE_PATH:?GW_WORKTREE_PATH is required}"
: "${GW_MAIN_REPO_PATH:?GW_MAIN_REPO_PATH is required}"

# $HOME 完全一致か、直後が `/` の場合だけ短縮する
# (境界を見ない前方一致だと /Users/<name>foo が ~foo になる)
tildify() {
  local tilde='~'
  case "$1" in
    "$HOME") printf '%s' "$tilde" ;;
    "$HOME"/*) printf '%s%s' "$tilde" "${1#"$HOME"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# GW_WORKTREE_PATH がディレクトリでないと herdr 側で落ちる (不在なら worktree_not_found)。
# 原因が分かる形で先に止める
if [ ! -d "$GW_WORKTREE_PATH" ]; then
  echo "post-create: GW_WORKTREE_PATH is not a directory: $(tildify "$GW_WORKTREE_PATH")" >&2
  exit 1
fi

repo_name="$(basename "$GW_MAIN_REPO_PATH")"
branch="${GW_BRANCH_NAME:-$(basename "$GW_WORKTREE_PATH")}"
# メインリポジトリの checkout は worktree グループの親になる
if [ "$GW_WORKTREE_PATH" = "$GW_MAIN_REPO_PATH" ]; then
  label="$repo_name"
else
  label="$repo_name:$branch"
fi

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
  # session 名は ~/.config/herdr/sessions/<name>/ のディレクトリ名になるため文字を絞る
  session="$(printf '%s' "$repo_name" | tr -cs 'A-Za-z0-9._-' '-')"
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
  # 絞り込みを jq 内で完結させる。`| head -n 1` にすると pipefail 下で
  # jq が SIGPIPE を受けてパイプライン全体が失敗しうる
  herdr --session "$session" pane list --workspace "$ws_id" \
    | jq -r 'first(.result.panes[]? | select(.agent == "claude") | .pane_id) // empty'
}

hunk_pane=""

# worktree open で開くと workspace に Git provenance が付き、親リポジトリの
# workspace と同じグループとしてサイドバーに並ぶ (--cwd はメインリポジトリを指す)。
# 既存があれば already_open として同じ workspace が返る
if ! ws_json=$(herdr --session "$session" worktree open \
  --cwd "$GW_MAIN_REPO_PATH" \
  --path "$GW_WORKTREE_PATH" \
  --label "$label" \
  "$focus_flag"); then
  echo "post-create: herdr worktree open failed (label: $label, path: $(tildify "$GW_WORKTREE_PATH"))" >&2
  exit 1
fi
ws_id=$(echo "$ws_json" | jq -r '.result.workspace.workspace_id // empty')
# root_pane は already_open の真偽によらず返り、同じ応答の tab の root pane を指す
root_pane=$(echo "$ws_json" | jq -r '.result.root_pane.pane_id // empty')
if [ -z "$ws_id" ] || [ -z "$root_pane" ]; then
  echo "post-create: herdr worktree open returned no workspace/root pane (label: $label, path: $(tildify "$GW_WORKTREE_PATH"))" >&2
  exit 1
fi
reused=$(echo "$ws_json" | jq -r '.result.already_open // false')
if [ "$reused" != "true" ] && [ "$reused" != "false" ]; then
  echo "post-create: herdr worktree open returned a non-boolean already_open: $reused (label: $label, path: $(tildify "$GW_WORKTREE_PATH"))" >&2
  exit 1
fi

if [ "$reused" = "true" ]; then
  claude_pane=$(find_claude_pane "$ws_id")
  # 子セッション起動目的の呼び出しで呼び出し元自身のペインが解決されると、
  # そのペインへ claude 起動コマンドが送られ、呼び出し元が自分自身に依頼を送ることになる。
  # どちらの送出よりも前で止める
  if [ -n "$hdr_gw_child" ] && [ "${claude_pane:-$root_pane}" = "${HERDR_PANE_ID:-}" ]; then
    echo "post-create: resolved pane is the caller's own pane (claude pane: ${claude_pane:-none}, root pane: $root_pane, label: $label, path: $(tildify "$GW_WORKTREE_PATH"))" >&2
    exit 1
  fi
  if [ -z "$claude_pane" ]; then
    # 既存 workspace に claude を報告しているペインが見つからない
    # (claude が終了している等) 場合、root pane で claude を起動し直す
    claude_pane="$root_pane"
    herdr --session "$session" pane send-text "$claude_pane" "$claude_launch_cmd"$'\n' > /dev/null 2>&1 || true
  fi
else
  claude_pane="$root_pane"

  # hunk ペインは無くても以降の処理は成立するため、分割失敗では止めない
  if split_json=$(herdr --session "$session" pane split "$claude_pane" \
    --direction right \
    --cwd "$GW_WORKTREE_PATH" \
    --no-focus); then
    hunk_pane=$(echo "$split_json" | jq -r '.result.pane.pane_id // empty')
  fi

  herdr --session "$session" pane send-text "$claude_pane" "$claude_launch_cmd"$'\n' > /dev/null 2>&1 || true
  if [ -n "$hunk_pane" ]; then
    herdr --session "$session" pane send-text "$hunk_pane" $'hunk diff --watch\n' > /dev/null 2>&1 || true
  fi
fi

if [ -n "$format_json" ]; then
  jq -cn \
    --arg workspace_id "$ws_id" \
    --arg claude_pane_id "$claude_pane" \
    --arg hunk_pane_id "$hunk_pane" \
    --argjson reused "$reused" \
    '{workspace_id: $workspace_id, claude_pane_id: $claude_pane_id}
     + (if $hunk_pane_id != "" then {hunk_pane_id: $hunk_pane_id} else {} end)
     + {reused: $reused}'
fi
