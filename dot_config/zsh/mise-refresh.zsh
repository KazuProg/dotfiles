# mise upgrade は postinstall hook を発火しないため (jdx/mise 仕様) shell 側で補う。
# sheldon の dotfiles-zsh plugin 経由で mise activate の後に load される。
if (( $+functions[mise] )) && (( ! $+functions[__mise_original] )); then
  functions[__mise_original]=$functions[mise]
  mise() {
    __mise_original "$@"
    local ret=$?
    case "${1:-}" in
      upgrade | up | self-update)
        "${XDG_CONFIG_HOME:-$HOME/.config}/mise/refresh-tool-links.sh"
        ;;
    esac
    return $ret
  }
fi
