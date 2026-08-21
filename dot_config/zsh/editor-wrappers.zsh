# Editors launched from within a herdr session inherit the env vars herdr
# injects into the pane (HERDR_ENV etc.), which trigger nested-herdr detection
# in their integrated terminal.
# Strip those only; user-set vars such as HERDR_CONFIG_PATH must survive.
_strip_herdr_env() {
	(
		unset HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID
		"$@"
	)
}
code() { _strip_herdr_env command code "$@"; }
zed() { _strip_herdr_env command zed "$@"; }
