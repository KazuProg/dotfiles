#!/bin/bash
set -euo pipefail

export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export CARGO_HOME="${XDG_DATA_HOME}/cargo"
export PATH="${HOME}/.local/bin:${CARGO_HOME}/bin:${PATH}"

mise install
eval "$(mise activate bash)"

export GOBIN="${HOME}/.local/bin"
go install mvdan.cc/sh/v3/cmd/shfmt@latest
go install github.com/evilmartians/lefthook/v2@latest
