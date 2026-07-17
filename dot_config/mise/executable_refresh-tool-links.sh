#!/usr/bin/env bash
# mise install / upgrade 後に、ツールが提供する外部リソース (skills / completions 等)
# の symlink・生成物を最新版に貼り直す。
set -euo pipefail

if command -v hunk > /dev/null 2>&1; then
  src=$(dirname "$(hunk skill path)")
  mkdir -p ~/.claude/skills
  ln -sfn "$src" ~/.claude/skills/hunk-review
fi

if command -v herdr > /dev/null 2>&1; then
  mkdir -p ~/.config/zsh/completions
  tmp=$(mktemp ~/.config/zsh/completions/_herdr.XXXXXX)
  if herdr completion zsh > "$tmp"; then
    mv "$tmp" ~/.config/zsh/completions/_herdr
  else
    rm -f "$tmp"
    exit 1
  fi
fi
