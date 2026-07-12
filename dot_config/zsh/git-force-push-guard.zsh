git() {
  if [[ "$1" == "push" ]]; then
    local arg
    for arg in "${@:2}"; do
      case "$arg" in
        --) break ;;
        -f|--force|--force-with-lease|--force-with-lease=*)
          if [[ "${SKIP_FPUSH_HOOK:-0}" != "1" ]]; then
            echo >&2
            echo "error: force-push detected." >&2
            echo "  use \`git fpush\` instead (PR に差分コメントを自動投稿します)." >&2
            echo "  bypass: SKIP_FPUSH_HOOK=1 git push ..." >&2
            echo >&2
            return 1
          fi
          ;;
      esac
    done
  fi
  command git "$@"
}
