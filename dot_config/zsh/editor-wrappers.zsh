# code from within a herdr session inherits HERDR_* env vars, which triggers
# nested-herdr detection in the VS Code integrated terminal. Strip them here.
_strip_herdr_env() {
	env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID "$@"
}
code() { _strip_herdr_env command code "$@"; }
zed() { _strip_herdr_env command zed "$@"; }
