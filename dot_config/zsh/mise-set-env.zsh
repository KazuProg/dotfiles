mise-set-env() {
    local file_args=()
    if [[ "$1" == "-g" ]]; then
        file_args=(--file "${HOME}/.config/mise/config.local.toml")
        shift
    fi
    if [[ -z "$1" ]]; then
        echo "usage: mise-set-env [-g] KEY [KEY ...]" >&2
        return 1
    fi
    mise set "${file_args[@]}" \
        --age-encrypt \
        --age-ssh-recipient "${HOME}/.ssh/id_ed25519.pub" \
        --prompt "$@"
}
