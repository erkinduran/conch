#!/bin/bash

set -efu
shopt -s nullglob

source 'app/globals.sh'
source 'config/app.sh'

# `LOG_LEVEL` as a number, compared by the log functions: no string match per line
case "$LOG_LEVEL" in
	debug)	_LOG_LEVEL=3 ;;
	info)	_LOG_LEVEL=2 ;;
	error)	_LOG_LEVEL=1 ;;
	*)	_LOG_LEVEL=0 ;;
esac

# `set -f` above turns globbing off, so the pattern would be sourced as a literal
# filename; `set +f` for the loop's one expansion, then back off
set +f
for filename in app/helpers/*.sh; do
	source "$filename"
done
set -f

# the database: the settings, the connection, the one configured driver, Redis, the models
source 'config/database.sh'
source 'app/database/connection.sh'
if [ ! -f "app/database/drivers/$DB_CONNECTION.sh" ]; then
	printf 'MISCONFIGURED: no database driver '"'"'%s'"'"' (DB_CONNECTION)\n' "$DB_CONNECTION" >&2
	exit 1
fi
source "app/database/drivers/$DB_CONNECTION.sh"
source 'app/database/redis.sh'
source 'app/database/model.sh'
set +f
for filename in app/models/*.sh; do
	source "$filename"
done
set -f

# Public: Log an information line: written when `LOG_LEVEL` is `info` or `debug` (see
# config/app.sh), so not in production by default.
#
# Takes as many arguments as needed. they will all be written, separated by newlines.
#
# Control bytes in a message become a `.`: these lines quote client bytes as received —
# the access line's target, the reason lines' header values — and a raw ESC or CR among
# them would write terminal escapes or forged-looking lines into the journal an admin
# greps. Only the newline is spared, as the separator this function itself documents;
# no client-sent string can carry one, `read` splits on it.
#
# Use it for the one line per response written by `_send_header()` and the reason a
# request was refused (404, 400...): the client's doing. A fault of the server itself
# goes to `log_error()`, the full dumps to `log_debug()`.
#
# Examples
#
#    log "> HTTP/1.1 200 OK
#
# will output
#
#    > HTTP/1.1 200 OK
function log()
{
	if [ "$_LOG_LEVEL" -ge 2 ]; then
		_log_write "$@"
	fi
}
export -f log

# Public: Log an error of the server itself (misconfiguration, database, Redis): written
# unless `LOG_LEVEL` is `none`, production included.
#
# Examples
#
#    log_error "MISCONFIGURED: view '$file' not found"
function log_error()
{
	if [ "$_LOG_LEVEL" -ge 1 ]; then
		_log_write "$@"
	fi
}
export -f log_error

function _log_write()
{
	local -a messages=("$@")
	# the class spells out C0 minus the newline, plus DEL — a locale-proof range, same
	# reason as `_HTTP_TOKEN_REGEX`. Expanded unquoted: quoted, the `-` turns literal
	# and the range falls apart
	local -r controls=$'\001-\011\013-\037\177'
	printf '%s\n' "${messages[@]//[$controls]/.}" >&2
}
export -f _log_write

# Public: Same as `log()`, but only when `LOG_LEVEL` is `debug`.
#
# `server.sh --debug` turns it on. It writes the full request and response dumps, which
# are a dozen lines per request: enough to hit the rate limit of a log collector.
#
# Takes as many arguments as needed. they will all be written, separated by newlines.
#
# Examples
#
#    log_debug "> Content-Type: text/html"
function log_debug()
{
	if [ "$_LOG_LEVEL" -ge 3 ]; then
		printf '%s\n' "$@" >&2
	fi
}
export -f log_debug
