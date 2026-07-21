# `hunk diff pr [<PR番号>] [flags]` を追加。base...HEAD の revspec に展開して hunk diff に委譲する。
# PR番号省略時は現在ブランチに紐づく PR を gh から取得。
hunk() {
	if [[ "$1" == "diff" && "$2" == "pr" ]]; then
		shift 2
		local pr_arg=""
		if [[ -n "$1" && "$1" != -* ]]; then
			pr_arg="$1"
			shift
		fi
		local base
		base=$(gh pr view $pr_arg --json baseRefName -q .baseRefName) || return
		if [[ -n "$pr_arg" ]]; then
			gh pr checkout "$pr_arg" || return
		fi
		command hunk diff "origin/${base}...HEAD" "$@"
		return
	fi
	command hunk "$@"
}
