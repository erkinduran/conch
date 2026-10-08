#!/bin/bash

set -efu

# Redis without a client program: bash opens the TCP socket itself (`/dev/tcp`) and speaks
# RESP, the protocol being simple enough. No fork at all, about half a millisecond per
# command. The connection opens on the first `redis()` call and lasts the request.

# Public: Run one Redis command. Each argument is one word of the command, sent as is: no
# quoting, spaces and newlines are fine.
#
# The reply lands in `REDIS_TYPE` and `REDIS_REPLY`:
#
#    status  `+OK`: REDIS_REPLY is the text
#    int     an integer
#    bulk    a string (empty allowed)
#    nil     no value (a missing key): REDIS_REPLY is empty
#    array   the items are in `REDIS_ARRAY`, REDIS_REPLY is their count
#
# An error reply (`-ERR ...`) or a dead connection is logged and returns 1.
#
# Examples
#
#    redis SET "user:$id:name" "$name"
#    redis GET "user:$id:name" && name="$REDIS_REPLY"
#    redis HGETALL "user:$id" && printf '%s\n' "${REDIS_ARRAY[@]}"
function redis()
{
	if [ -z "$_REDIS_FD" ]; then
		_redis_connect || return 1
	fi
	# RESP lengths are in bytes
	local LC_ALL=C
	local command="*$#"$'\r\n' argument
	for argument in "$@"; do
		command+="\$${#argument}"$'\r\n'"$argument"$'\r\n'
	done
	if ! printf '%s' "$command" >&"$_REDIS_FD"; then
		_redis_drop 'connection lost'
		return 1
	fi
	_redis_read || return 1
	if [ "$REDIS_TYPE" = error ]; then
		log_error "REDIS ERROR: $REDIS_REPLY"
		return 1
	fi
}

function _redis_connect()
{
	# a failed `exec` redirection in a non-interactive shell would end the process; inside
	# a function with `||` it only returns, as tested. The braces carry the `2>/dev/null`:
	# bash's own "Connection refused" lines would ignore `LOG_LEVEL`, and on a bare `exec`
	# the redirection would close stderr for good
	if ! { exec {_REDIS_FD}<>"/dev/tcp/$REDIS_HOST/$REDIS_PORT"; } 2>/dev/null; then
		log_error "REDIS ERROR: cannot connect to $REDIS_HOST:$REDIS_PORT"
		_REDIS_FD=''
		return 1
	fi
	if [ -n "$REDIS_PASSWORD" ]; then
		redis AUTH "$REDIS_PASSWORD" || return 1
	fi
	if [ "$REDIS_DB" != 0 ]; then
		redis SELECT "$REDIS_DB" || return 1
	fi
}

function _redis_drop()
{
	log_error "REDIS ERROR: $1"
	exec {_REDIS_FD}>&- 2>/dev/null || true
	_REDIS_FD=''
}

# Read one reply, nested arrays flattened into `REDIS_ARRAY`
function _redis_read()
{
	local line count i
	if ! IFS= read -r -u "$_REDIS_FD" line; then
		_redis_drop 'connection closed'
		return 1
	fi
	line="${line%$'\r'}"
	case "${line:0:1}" in
		'+')	REDIS_TYPE=status; REDIS_REPLY="${line:1}" ;;
		'-')	REDIS_TYPE=error;  REDIS_REPLY="${line:1}" ;;
		':')	REDIS_TYPE=int;    REDIS_REPLY="${line:1}" ;;
		'$')
			count="${line:1}"
			if [ "$count" = -1 ]; then
				REDIS_TYPE=nil
				REDIS_REPLY=''
			else
				REDIS_TYPE=bulk
				IFS= read -r -u "$_REDIS_FD" -N "$count" REDIS_REPLY || true
				# the CRLF after the data
				IFS= read -r -u "$_REDIS_FD" -N 2 line || true
			fi ;;
		'*')
			count="${line:1}"
			REDIS_ARRAY=()
			if [ "$count" = -1 ]; then
				REDIS_TYPE=nil
				REDIS_REPLY=''
				return 0
			fi
			local -a items=()
			for (( i = 0; i < count; i++ )); do
				_redis_read || return 1
				items+=("$REDIS_REPLY")
			done
			REDIS_ARRAY=("${items[@]+"${items[@]}"}")
			REDIS_TYPE=array
			REDIS_REPLY="$count" ;;
		*)
			_redis_drop "protocol error, got '$line'"
			return 1 ;;
	esac
}
