#!/bin/bash

set -efu

# `[ -v 'array[key]' ]` needs 4.3; macOS' /bin/bash is 3.2, so there run `bash server.sh` with a newer one
if [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
	{ [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }; then
	printf 'Conch: bash >= 4.3 required, found %s (%s)\n' "$BASH_VERSION" "$BASH" >&2
	exit 1
fi

cd "$(dirname "$0")"

declare -r VERSION='1.1'

# computed once here rather than on every request: each would cost the dispatcher a fork
# C.UTF-8 is the Linux one, macOS only has the per-language ones
if locale -a 2>/dev/null | grep -qix 'c\.utf-\?8'; then
	export LC_ALL=C.UTF-8
else
	export LC_ALL=en_US.UTF-8
fi
# `init_environment` takes a `ROOT` it inherits as is
ROOT=$(realpath .)
export ROOT

# `.env`: `KEY=value` lines, exported for config/*.sh to find (see .env.example)
if [ -f .env ]; then
	set -a
	source .env
	set +a
fi

# the environment is the only thing bootstrap/app.sh and the scripts it runs inherit from us
if [ "${1:-}" = '--debug' ]; then
	export DEBUG=1
	shift
fi

if [ "${1:-}" = '--version' ]; then
	printf 'Conch %s\n' "$VERSION"
	exit 0
fi

# the mode and the log level (config/app.sh), checked once here rather than failing on
# every request, then exported for bootstrap/app.sh
source config/app.sh
case "$APP_ENV" in
	local|development|production) ;;
	*)	printf 'Conch: APP_ENV must be local, development or production, got %s\n' "$APP_ENV" >&2
		exit 1 ;;
esac
case "$LOG_LEVEL" in
	debug|info|error|none) ;;
	*)	printf 'Conch: LOG_LEVEL must be debug, info, error or none, got %s\n' "$LOG_LEVEL" >&2
		exit 1 ;;
esac
if [ "$APP_ENV" = production ] && [ "$LOG_LEVEL" = debug ]; then
	printf 'Conch: warning, debug logging in production writes every request and response in full\n' >&2
fi
export APP_ENV LOG_LEVEL

# the port: the argument, else `PORT` (from `.env` or the environment, as hosting
# platforms set it), else 3000
port="${1:-${PORT:-3000}}"
if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
	printf 'Conch: invalid port %s (argument or PORT)\n' "$port" >&2
	exit 1
fi

# Options for socat: everything a user may want to tune is one line here.
declare -a socat_options
# the listening port and IP stack — keep exactly one of the three *-LISTEN lines
# (ipv6only=0 makes the IPv6 socket answer IPv4 clients too; TCP4 doesn't know the option)
#socat_options+=("TCP4-LISTEN:$port")
socat_options+=("TCP6-LISTEN:$port" 'ipv6only=0')
# HTTPS: the same dual-stack listener behind TLS — generate the certificate first, see docs/https.md
# (pf=ip4 instead of pf=ip6,ipv6only=0 for IPv4 only; verify=0 = don't ask a *client* certificate)
#socat_options+=("OPENSSL-LISTEN:$port" 'pf=ip6' 'ipv6only=0')
#socat_options+=("cert=$PWD/certs/cert.pem" "key=$PWD/certs/key.pem")
#socat_options+=('verify=0' 'openssl-min-proto-version=TLS1.3')
# ~6 connections a browser opens per user, times the number of simultaneous users
socat_options+=('max-children=32')
# connections blocked by `max-children` wait in this queue
socat_options+=('backlog=32')
# the server model itself, do not change: fork one dispatcher per connection, rebind
# the port immediately on restart, close the socket fully when the dispatcher exits
socat_options+=('reuseaddr' 'fork' 'end-close')

# the IFS=',' join below would silently split any option that contains a comma itself —
# typically a checkout path with one in it, reaching the array through cert=/key=
case "${socat_options[*]}" in
	*,*)	printf 'Conch: no socat option may contain a comma (check the path to the checkout)\n' >&2
		exit 1
		;;
esac

printf 'Conch %s started in %s mode (log level %s), listening on %s\n' \
	"$VERSION" "$APP_ENV" "$LOG_LEVEL" "$port" >&2


# IFS joins the array into socat's one comma-separated argument, and dies with the exec
IFS=','
# exec: socat replaces us, so systemd tracks and signals it instead of a bash wrapper
# -T: drop a connection that goes silent, so a client can't pin a forked child forever
exec socat \
	-T 10 \
	"${socat_options[*]}" \
	EXEC:"$BASH ./bootstrap/app.sh"