python_venv_chpwd() {
  local dir="$PWD" venv_dir=""

  # 親ディレクトリを遡って .venv を探す
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/.venv/bin/activate" ]]; then
      venv_dir="$dir/.venv"
      break
    fi
    dir="${dir:h}"
  done

  if [[ -n "$venv_dir" ]]; then
    if [[ "$VIRTUAL_ENV" != "$venv_dir" ]]; then
      source "$venv_dir/bin/activate"
    fi
  elif [[ -n "$VIRTUAL_ENV" ]]; then
    deactivate 2>/dev/null
  fi
}

autoload -Uz add-zsh-hook
add-zsh-hook chpwd python_venv_chpwd
python_venv_chpwd
