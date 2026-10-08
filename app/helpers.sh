#!/bin/bash

set -efu
shopt -s nullglob

source 'app/globals.sh'

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

# Public: Log any messages in the error outut of the script (default is console).
#
# Takes as many arguments as needed. they will all be written, separated by newlines.
#
# Control bytes in a message become a `.`: these lines quote client bytes as received —
# the access line's target, the reason lines' header values — and a raw ESC or CR among
# them would write terminal escapes or forged-looking lines into the journal an admin
# greps. Only the newline is spared, as the separator this function itself documents;
# no client-sent string can carry one, `read` splits on it.
#
# Use it for what is worth keeping on a busy server: errors, and the one line per
# response written by `_send_header()`. Everything else belongs in `log_debug()`.
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
	local -a messages=("$@")
	# the class spells out C0 minus the newline, plus DEL — a locale-proof range, same
	# reason as `_HTTP_TOKEN_REGEX`. Expanded unquoted: quoted, the `-` turns literal
	# and the range falls apart
	local -r controls=$'\001-\011\013-\037\177'
	printf '%s\n' "${messages[@]//[$controls]/.}" >&2
}
export -f log

# Public: Same as `log()`, but only when debug logging is on.
#
# Debug logging is off unless `DEBUG` is `1` in the environment, which
# `server.sh --debug` does. It turns on the full request and response dumps, which are
# a dozen lines per request: enough to hit the rate limit of a log collector.
#
# Takes as many arguments as needed. they will all be written, separated by newlines.
#
# Examples
#
#    log_debug "> Content-Type: text/html"
function log_debug()
{
	if [ "$DEBUG_LOG" = 1 ]; then
		printf '%s\n' "$@" >&2
	fi
}
export -f log_debug
