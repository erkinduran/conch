#!/bin/bash

set -efu

# Internal: Log a request parse failure, dump the request when relevant, and answer an error.
#
# **Note:** this method is used by `_read_request_line()` and `_read_request_headers()` and
# shouldn't be called manually.
#
# Owns the bail-out invariant of `read_request()`: the request is dumped on the first parse
# only (a child script re-parse would dump it once per script), the reason is always
# `log`ged, and `send_error()` ends the process — this function never returns. Only for the
# bail-outs *before* the end of the header loop: after that point, the first parse has
# already dumped the full request unconditionally, and this would dump it a second time —
# which is why `_read_request_body()` calls `send_error()` directly.
#
# $1 - the HTTP error code, one of the keys of `HTTP_RESPONSE`
# $2 - the reason, `log`ged as is
# $3 - true when parsing from the standard input, false in a child script re-parse
#
# Examples
#
#    _bail_request 400 'BAD REQUEST: malformed request line' true
function _bail_request()
{
	if [ "$3" = true ]; then
		log_debug "$REQUEST_FULL_STRING"
	fi
	log "$2"
	send_error "$1"
}
export -f _bail_request

# Internal: Read and validate the request line, and parse the URL.
#
# **Note:** this method is used by `read_request()` and shouldn't be called manually.
#
# Reads the first line of the input stream and fills `REQUEST_METHOD`, `REQUEST_URL` and
# `REQUEST_HTTP_VERSION` — plus `URL_BASE` and `URL_PARAMETERS` through `parse_url()`.
# `REQUEST_FULL_STRING` starts here, with the raw line.
#
# An absolute-form request target (`GET http://host/path`, RFC 9112 §3.2.2) is rewritten to
# the path it points at, and its authority — validated first — is stored in
# `_REQUEST_AUTHORITY` for `_read_request_headers()` to apply. Any other target that is not
# a path is refused with a 400, the asterisk form of `OPTIONS` excepted.
#
# $1 - true when parsing from the standard input, false when re-parsing, see `read_request()`
#
# Examples
#
#    _read_request_line true
function _read_request_line()
{
	local line
	# this bail-out and the 414 below stay outside `_bail_request`: `REQUEST_FULL_STRING`
	# is not filled yet, so its debug dump would be empty
	if ! read -r line; then
		log 'BAD REQUEST: empty request'
		send_error 400
	fi
	# checked before we touch the string: `send_error` runs `cat`, which fails just the same
	# once the environment is too big, and the suffix strip below is quadratic in bash
	if [ "${#line}" -gt "$MAX_HEADERS_SIZE" ]; then
		log "TOO LARGE: request line over the $MAX_HEADERS_SIZE characters limit"
		send_error 414
	fi
	line=${line%%$'\r'}
	REQUEST_FULL_STRING="$line"

	# read URL
	read -r REQUEST_METHOD REQUEST_URL REQUEST_HTTP_VERSION <<< "$line"
	_REQUEST_TARGET="$REQUEST_URL"	# saved before the rewrite below, for the access log
	# `read` collapses SP/TAB runs and drops trailing blanks (a leniency RFC 9112 §3 grants),
	# so only non-whitespace extra tokens get glued into the version and rejected here.
	if [ -z "$REQUEST_METHOD" ] || [ -z "$REQUEST_URL" ] \
			|| [[ ! "$REQUEST_HTTP_VERSION" =~ ^HTTP/[[:digit:]]\.[[:digit:]]$ ]]; then
		_bail_request 400 'BAD REQUEST: malformed request line' "$1"
	fi
	# a literal `HTTP/0.9` token means the client speaks the 1.x line format (real 0.9 has no
	# version token and took the 400 above), so a headered 505 is safe here (RFC 9112 §2.3)
	if [[ "$REQUEST_HTTP_VERSION" != HTTP/1.* ]]; then
		_bail_request 505 "UNSUPPORTED VERSION: '$REQUEST_HTTP_VERSION'" "$1"
	fi
	# RFC 9112 §3: a method is a token (RFC 9110 §5.6.2 tchar), so a stray octet in it is a
	# malformed request line — a 400 — where a well-formed unknown method is a 501 below
	if [[ ! "$REQUEST_METHOD" =~ $_HTTP_TOKEN_REGEX ]]; then
		_bail_request 400 "BAD REQUEST: invalid method token '$REQUEST_METHOD'" "$1"
	fi
	# Membership test and not a `case` pattern: a variable expanded into a pattern has its
	# `|` taken literally, which would silently match nothing. Exact because the tchar check
	# above keeps the `,` delimiter out of the method, so it cannot span two list entries.
	# Method names are case sensitive (RFC 9110 §9.1): a lowercase `get` is not a GET
	if [[ ",${SUPPORTED_METHODS// /}," != *",$REQUEST_METHOD,"* ]]; then
		case "$REQUEST_METHOD" in
			# a method we know but don't serve: 405 MUST carry `Allow` (RFC 9110 §15.5.6)
			PUT|DELETE|PATCH|TRACE|CONNECT)
				add_header 'Allow' "$SUPPORTED_METHODS"
				_bail_request 405 "METHOD NOT ALLOWED: '$REQUEST_METHOD'" "$1"
				;;
			# a method we don't know at all is a 501, not a 405 (RFC 9110 §9.1)
			*)
				_bail_request 501 "METHOD NOT IMPLEMENTED: '$REQUEST_METHOD'" "$1"
				;;
		esac
	fi
	# RFC 9112 §3.2.2: the absolute-form target a proxy sends MUST be accepted. Rewritten to
	# the origin form here, before anything reads the URL, so that `parse_url`,
	# `_resolve_path` and the child scripts only ever see a path. Only the scheme is case
	# insensitive (RFC 3986 §3.1), so everything is cut out of the original
	if [[ "${REQUEST_URL,,}" =~ ^https?:// ]]; then
		# a fragment is no part of a request-target (RFC 9112 §3.2), so it is cut off
		# here rather than glued back onto the path
		local -r target="${REQUEST_URL%%#*}"
		# the authority ends at the first `/` or `?` (RFC 3986 §3.2), and what follows it
		# keeps its own delimiter — cutting on `/` alone would eat a `?query`
		local rest="${target#*://}"
		_REQUEST_AUTHORITY="${rest%%[/?]*}"
		rest="${rest:${#_REQUEST_AUTHORITY}}"
		# RFC 9110 §4.2: an empty host — bare or in front of a `:port` — is invalid in an
		# http(s) URI and userinfo is an error — and nothing downstream `_check_encoding`s
		# what lands in `Host` here
		if [ -z "${_REQUEST_AUTHORITY%%:*}" ] || [[ "$_REQUEST_AUTHORITY" == *@* ]] \
				|| ! _check_encoding "$_REQUEST_AUTHORITY"; then
			_bail_request 400 "BAD REQUEST: invalid authority in '$REQUEST_URL'" "$1"
		fi
		REQUEST_URL="/${rest#/}"	# an absolute URI needs no path, and no path is the root
	fi
	# RFC 9112 §3.2: past the rewrite the target must be a path — the asterisk form, that
	# only `OPTIONS` may use, is the one exception. Nothing else may reach the routing
	if [[ "$REQUEST_URL" != /* ]] && [ "$REQUEST_METHOD $REQUEST_URL" != 'OPTIONS *' ]; then
		_bail_request 400 "BAD REQUEST: unsupported request target '$REQUEST_URL'" "$1"
	fi
	# `parse_url` decodes the URL, so a broken encoding can't be answered
	if ! _check_encoding "$REQUEST_URL"; then
		_bail_request 400 "BAD REQUEST: invalid percent encoding in '$REQUEST_URL'" "$1"
	fi
	# fill URL_*
	parse_url "$REQUEST_URL"
}
export -f _read_request_line

# Internal: Read the header lines and fill `REQUEST_HEADERS`.
#
# **Note:** this method is used by `read_request()` and shouldn't be called manually.
#
# Reads the input stream up to the empty line that ends the headers, appending each line to
# `REQUEST_FULL_STRING` on the way.
#
# A header line is refused with a 400 when it is folded (obs-fold), has no colon, still
# carries a CR once its own terminator is stripped, or has a name that is not a token —
# whitespace before the colon included (RFC 9112 §5, §5.1, §5.2 and RFC 9110 §5.5).
# A repeated header becomes the `v1, v2` list of RFC 9110 §5.2 — except `Cookie`, whose
# pairs recombine on `; ` (RFC 9113 §8.2.3) — but a repeated `Host`, `Content-Length` or
# `Content-Type` with two different values is a 400: they frame the request, and none of
# the three is a list. A repeated `Host` is ignored instead, without being compared, when
# the request-target already carried an authority.
#
# Once the loop is done, any HTTP/1.1+ request without a `Host` header is refused with a
# 400 — absolute-form included, RFC 9112 §3.2.2 only voids the header's value — then the
# `_REQUEST_AUTHORITY` of an absolute-form target replaces `REQUEST_HEADERS['host']`.
#
# $1 - true when parsing from the standard input, false when re-parsing, see `read_request()`
#
# Examples
#
#    _read_request_headers true
function _read_request_headers()
{
	local line key name value separator
	# `IFS=` is load-bearing: the default one strips the leading SP/HTAB of a line, so the
	# obs-fold check below could never fire and a continuation carrying a colon would be
	# de-folded into a header of its own — and a whitespace-only line would collapse to the
	# empty string and `break` the loop, dropping every header behind it
	while IFS= read -r line; do
		# checked first, for the same reasons as the request line
		if [ $(( ${#REQUEST_FULL_STRING} + ${#line} + 1 )) -gt "$MAX_HEADERS_SIZE" ]; then
			_bail_request 431 "TOO LARGE: headers over the $MAX_HEADERS_SIZE characters limit" "$1"
		fi
		line=${line%%$'\r'}
		# reached the end of the headers, break.
		if [ -z "$line" ]; then
			break
		fi
		REQUEST_FULL_STRING="$REQUEST_FULL_STRING
$line"
		# RFC 9110 §5.5: a CR surviving the line's own terminator must be refused or blanked,
		# and refusing is this parser's way. Kept, a line ending `\r\r\n` loses one CR per
		# parse, so the child re-parse of `REQUEST_FULL_STRING` reads another value than this
		if [[ "$line" == *$'\r'* ]]; then
			_bail_request 400 'BAD REQUEST: stray carriage return in a header line' "$1"
		fi
		# RFC 9112 §5.2: a line starting with whitespace is an obs-fold continuation, which a
		# server must reject or splice. Rejecting is the honest half — spliced, it would have
		# to be re-split here and re-folded in `REQUEST_FULL_STRING` for the child re-parse
		if [[ "$line" == [[:space:]]* ]]; then
			_bail_request 400 'BAD REQUEST: obsolete line folding in the headers' "$1"
		fi
		key="${line%%:*}"	# cut out of the raw line: the `read` below eats what we refuse
		# RFC 9112 §5: a field line is `name ":" OWS value OWS`, so with no colon there is no
		# field at all — and a bare `Host` line used to satisfy the presence check below
		if [ "$key" = "$line" ]; then
			_bail_request 400 "BAD REQUEST: header line without a colon: '$line'" "$1"
		fi
		# a field name is a token (RFC 9110 §5.6.2), so this one test covers the whitespace
		# before the colon that RFC 9112 §5.1 MUSTs out (a request smuggling vector: a proxy
		# that trimmed it instead would forward a header we never saw), the empty name that is
		# a fatal `bad array subscript`, and any stray octet
		if [[ ! "$key" =~ $_HTTP_TOKEN_REGEX ]]; then
			_bail_request 400 "BAD REQUEST: invalid header name '$key'" "$1"
		fi
		name="${key,,}"	# header names are case insensitive
		IFS=$' \t' read -r value <<< "${line#*:}"	# strips the OWS, and only the OWS
		# the subscripts are quoted throughout: a field name may legally be `*`, and unquoted
		# that one would read as every element of the array. `[[` and never `[`: the latter
		# re-expands the subscript it is handed, so a name holding a backquote or a `$` — both
		# of them tchar — would run a command, or abort the whole dispatcher under `set -u`
		if [[ ! -v REQUEST_HEADERS["$name"] ]]; then
			REQUEST_HEADERS["$name"]="$value"
		else
			case "$name" in
				host|content-length|content-type)
					# RFC 9112 §3.2.2: with an absolute-form target its authority wins and
					# every `Host` line MUST be ignored, so two conflicting ones are no
					# ambiguity to refuse here
					if [ "$name" = 'host' ] && [ -n "$_REQUEST_AUTHORITY" ]; then
						continue
					fi
					# none of those three is a list: two `Host` values make the target
					# ambiguous (RFC 9112 §3.2), two `Content-Length` values the body framing
					# (§6.3) — the request smuggling pair — and two `Content-Type` values the
					# body parse, where `_read_request_body` cuts the merged list back at its
					# first `;` and would read one media type out of two. Repeated identical
					# values are unambiguous, they pass
					if [ "${REQUEST_HEADERS["$name"]}" != "$value" ]; then
						_bail_request 400 "BAD REQUEST: conflicting '$key' headers" "$1"
					fi
					continue	# never merged: an identical repeat collapses into the stored value
					;;
				cookie)
					# RFC 6265 §5.4 forbids repeating `Cookie`, but RFC 9113 §8.2.3 lets an
					# HTTP/2 hop split it — and it recombines on `; `, never on a comma
					separator='; '
					;;
				*)
					# RFC 9110 §5.2: a repeated field is the comma-separated list it stands
					# for. Overwriting instead would drop what the client sent, and a header
					# we compare as a whole (`If-None-Match`...) degrades to a full answer
					separator=', '
					;;
			esac
			# an empty element is ignorable anyway (RFC 9110 §5.6.1), so it never enters the
			# list: a stored empty value is replaced, an incoming empty value is dropped
			if [ -z "${REQUEST_HEADERS["$name"]}" ]; then
				REQUEST_HEADERS["$name"]="$value"
			elif [ -n "$value" ]; then
				REQUEST_HEADERS["$name"]="${REQUEST_HEADERS["$name"]}$separator$value"
			fi
		fi
	done
	if [ "$1" = true ]; then
		log_debug "$REQUEST_FULL_STRING"
	fi
	# RFC 9112: §3.2 requires Host on 1.1 — absolute-form included, whose §3.2.2 only voids
	# the header's value, never its presence — and §2.3 processes a higher 1.x minor as 1.1,
	# so only 1.0 is exempt. Checked before the rewrite below, which would mask the absence
	if [ "$REQUEST_HTTP_VERSION" != 'HTTP/1.0' ] && [ ! -v "REQUEST_HEADERS['host']" ]; then
		log "BAD REQUEST: $REQUEST_HTTP_VERSION request without a Host header"
		send_error 400
	fi
	# RFC 9112 §3.2.2: with an absolute-form target, its authority wins and the `Host` header
	# MUST be ignored. Done here and not with the rewrite in `_read_request_line()`, where
	# the header loop would then let a `Host:` line overwrite it and invert the MUST
	if [ -n "$_REQUEST_AUTHORITY" ]; then
		REQUEST_HEADERS['host']="$_REQUEST_AUTHORITY"
	fi
}
export -f _read_request_headers

# Internal: Discard what may still arrive of a request body that will not be read.
#
# **Note:** this method is used by `_read_request_body()` and shouldn't be called manually.
#
# Answering a request whose body is still in flight and exiting leaves unread bytes in the
# socket, and closing over them is a TCP reset that can destroy the answer — error page or
# 200 alike — before the client reads it. This is the lingering close of every real server, bounded both ways so
# a client can't pin the process: at most 64 kio are discarded, and a stalled stream is
# waited on for one 0.2 s timeout. A client blasting past the cap may still see the reset.
#
# Examples
#
#    _drain_request_input
#    send_error 413
function _drain_request_input()
{
	local -i i
	local _discard
	for (( i = 0; i < 16; i++ )); do
		# `-N` so a newline doesn't end a read early, C locale so it counts bytes
		if ! IFS= LC_ALL=C read -r -t 0.2 -N 4096 _discard; then
			break
		fi
	done
}
export -f _drain_request_input

# Internal: Read the body of a POST and fill `REQUEST_BODY` and `REQUEST_BODY_PARAMETERS`.
#
# **Note:** this method is used by `read_request()` and shouldn't be called manually.
#
# A `Transfer-Encoding` is inspected first, on any method: next to a `Content-Length` it
# is the request smuggling pair of RFC 9112 §6.3, a `400` on presence alone. A lone
# `chunked` is the only value even recognized, and it is refused too — not decoded — with
# the `411` the same section sanctions; any other value gets the `400` it MUSTs for a
# non-final chunked, since no coding will ever be decoded here there is no `501` worth
# telling apart. An emptied value is no coding at all (RFC 9110 §5.6.1, the header
# merge's own rule) and the request goes on bodyless. Past that gate, nothing is read
# unless the request is a POST carrying a `Content-Length` — one announced on any other
# method is drained, unread, so the answer is not lost to a TCP reset. The length is
# checked against `MAX_BODY_SIZE` before it is trusted, and the body lands in
# `REQUEST_FULL_STRING` too.
#
# A body of type `application/x-www-form-urlencoded` is decoded into
# `REQUEST_BODY_PARAMETERS`.
#
# A client that announced `Expect: 100-continue` (RFC 9110 §10.1.1) is holding the body
# back, so the interim `HTTP/1.1 100 Continue` line is written right before the body
# read. Every refusal above it answers with a final status instead — the alternative the
# same section allows. No interim line goes to an HTTP/1.0 client (a MUST NOT), whose
# expectation is ignored. `Expect` is a list, and naming anything but `100-continue` in
# it is a `417 Expectation Failed`, on any method (a MAY): a client waiting on an
# expectation we will never meet learns right away instead of timing out. An empty
# element names no expectation and is dropped, so an emptied value passes.
#
# No `_bail_request` here: every bail-out below sits after the header loop, which has
# already dumped the full request, so `send_error()` is called directly.
#
# $1 - true when reading from the standard input, false when re-parsing
#      `REQUEST_FULL_STRING` in a child script — the interim response is written only
#      once, by the first parse
#
# Examples
#
#    _read_request_body true
function _read_request_body()
{
	if [ -v "REQUEST_HEADERS['transfer-encoding']" ]; then
		# the TE + CL pair RFC 9112 §6.3 bans is a 400 on presence alone, emptied or not:
		# the header's presence is what a downstream parser may frame on
		if [ -v "REQUEST_HEADERS['content-length']" ]; then
			log 'BAD REQUEST: both Transfer-Encoding and Content-Length'
			_drain_request_input
			send_error 400
		fi
		local -r te_value="${REQUEST_HEADERS['transfer-encoding']}"
		# a lone chunked — coding names are case insensitive — is the only value even
		# recognized, and it is refused too, not decoded, with the 411 §6.3 sanctions
		if [ "${te_value,,}" = 'chunked' ]; then
			log 'LENGTH REQUIRED: chunked Transfer-Encoding is not decoded'
			_drain_request_input
			send_error 411
		# any other value is the 400 §6.3 MUSTs for a non-final chunked — no coding will
		# ever be decoded here, so there is no 501 worth telling apart — while an emptied
		# one names no coding at all (RFC 9110 §5.6.1) and the request goes on bodyless
		elif [ -n "$te_value" ]; then
			log "BAD REQUEST: unsupported Transfer-Encoding '$te_value'"
			_drain_request_input
			send_error 400
		fi
	fi
	# an expectation we won't meet is refused on any method (RFC 9110 §10.1.1 MAY): a
	# waiting client learns right away instead of timing out, and a 417 is still the
	# immediate final response §10.1.1 asks for. The value is the list §5.6.1 says it is:
	# a repeated 100-continue (the header loop merges repeated lines) still names only
	# the one expectation we meet, and an empty element names none at all — the header
	# merge's own rule — so an emptied value passes
	local expect_continue=false
	local -a expect_members
	local member
	IFS=',' read -ra expect_members <<< "${REQUEST_HEADERS['expect']:-}"
	for member in "${expect_members[@]}"; do
		IFS=$' \t' read -r member <<< "$member"	# strips the OWS around the element
		if [ -z "$member" ]; then
			continue
		fi
		if [ "${member,,}" != '100-continue' ]; then
			log "EXPECTATION FAILED: unsupported Expect '${REQUEST_HEADERS['expect']}'"
			# only a Content-Length announces a body here — a Transfer-Encoding was
			# refused above — and with none announced the drain would only sit out
			# its own read timeout
			if [ -v "REQUEST_HEADERS['content-length']" ]; then
				_drain_request_input
			fi
			send_error 417
		fi
		expect_continue=true
	done
	# past the gate above only a `Content-Length` announces a body, and only a POST's is
	# read. One announced on any other method is drained instead: left in the socket,
	# closing over it is the TCP reset the refusals here guard against — on a 200 this time.
	# First parse only: the parent has already emptied the socket for the child re-parse
	if [ "$REQUEST_METHOD" != 'POST' ]; then
		if [ "$1" = true ] && [ -v "REQUEST_HEADERS['content-length']" ]; then
			_drain_request_input
		fi
		return 0
	fi
	if [ ! -v "REQUEST_HEADERS['content-length']" ]; then
		return 0 # no body is OK
	fi
	local -r raw_length="${REQUEST_HEADERS['content-length']}"
	# a bogus length makes `read` fail with a bash error, and a huge one makes it wait
	# for bytes that will never come, so we check it before using it
	if [[ ! $raw_length =~ ^0*([[:digit:]]+)$ ]]; then
		log "BAD REQUEST: invalid Content-Length '$raw_length'"
		_drain_request_input
		send_error 400
	fi
	# the group drops the leading zeros `1*DIGIT` allows, so the cap below measures the
	# magnitude and not the padding — same rule as the Range parser
	local -r length="${BASH_REMATCH[1]}"
	# outside `test`'s integer range, `-gt` errors out and counts as false, which would
	# silently skip the limit. 10 digits is far above the limit anyway
	if [ "${#length}" -gt 10 ] || [ "$length" -gt "$MAX_BODY_SIZE" ]; then
		log "TOO LARGE: Content-Length '$length' over the $MAX_BODY_SIZE bytes limit"
		_drain_request_input
		send_error 413
	fi
	# RFC 9110 §10.1.1: the client is waiting for this line before it sends the body just
	# measured. Raw, not `_send_header()`: an interim response carries no header fields
	# here, no access-log line, and must not consume `RESPONSE_HEADERS`. Never to an
	# HTTP/1.0 client (§2.3 processes a higher 1.x minor as 1.1, same rule as the Host gate)
	if [ "$1" = true ] && [ "$expect_continue" = true ] \
		&& [ "$REQUEST_HTTP_VERSION" != 'HTTP/1.0' ]; then
		printf 'HTTP/1.1 100 %s\r\n\r\n' "${HTTP_RESPONSE[100]}"
		log_debug "> HTTP/1.1 100 ${HTTP_RESPONSE[100]}"
	fi
	# `Content-Length` counts bytes, but `-N` counts characters: in a UTF-8 locale a
	# multibyte body would make us wait for characters the client never sends
	local line
	if ! LC_ALL=C read -rN "$length" line; then
		log "BAD REQUEST: body ended before the $length bytes announced"
		send_error 400
	fi
	REQUEST_FULL_STRING="$REQUEST_FULL_STRING

$line"
	REQUEST_BODY="$line"
	# if content is of type "application/x-www-form-urlencoded", we parse it.
	# a media type is case insensitive and can carry parameters, like `;charset=UTF-8`
	local media_type="${REQUEST_HEADERS['content-type']:-}"
	media_type="${media_type%%;*}"
	media_type="${media_type//[[:space:]]/}"
	if [ "${media_type,,}" = 'application/x-www-form-urlencoded' ]; then
		if ! _check_encoding "$REQUEST_BODY"; then
			log 'BAD REQUEST: invalid percent encoding in the body'
			send_error 400
		fi
		_parse_parameters "$REQUEST_BODY" 'REQUEST_BODY_PARAMETERS'
	fi
}
export -f _read_request_body

# Internal: Read the client request and set up environment.
#
# **Note:** this method is used by the dispatcher and shouldn't be called manually.
#
# Reads the input stream and fills the following variables (also run `parse_url()`):
#
# * `REQUEST_METHOD`
# * `REQUEST_HTTP_VERSION`
# * `REQUEST_HEADERS`
# * `REQUEST_BODY`
# * `REQUEST_BODY_PARAMETERS`
# * `REQUEST_URL`
# * `URL_BASE`
# * `URL_PARAMETERS`
#
# The work happens in `_read_request_line()`, `_read_request_headers()` and
# `_read_request_body()`, which read the same input stream and must run in this order, in
# the current shell: a subshell or a command substitution would keep the variables — and
# the error page of a bail-out — to itself.
#
# *Note* that this method is highly inspired by [bashttpd](https://github.com/avleen/bashttpd)
#
# $1 - true when parsing from the standard input, false when re-parsing
#      `REQUEST_FULL_STRING` in a child script. Only the first parse logs the request, so
#      that a request is not dumped once per script it goes through
function read_request()
{
	_read_request_line "$1"
	_read_request_headers "$1"
	_read_request_body "$1"
}
export -f read_request
