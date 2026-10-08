#!/bin/bash

set -efu

# Public: Initialize the environment.
#
# This function should always be ran at the top of any scripts. Once this function has
# run, all the following variables will be available:
#
# * `ROOT`
# * `REQUEST_METHOD`
# * `REQUEST_URL`
# * `REQUEST_HTTP_VERSION`
# * `REQUEST_HEADERS`
# * `REQUEST_BODY`
# * `REQUEST_BODY_PARAMETERS`
# * `URL_BASE`
# * `URL_PARAMETERS`
# * `RESPONSE_HEADERS`
# * `HTTP_RESPONSE`
# * `MAX_BODY_SIZE`
# * `MAX_HEADERS_SIZE`
# * `REQUEST_FULL_STRING`
# * `DEBUG_LOG`
#
# To do so, it will read from the standard input the received request, and execute
# `read_request` to initialize everything.
#
# Then, it will export the full request in the environment variable `REQUEST_FULL_STRING`
# so it can always be reexecuted.
#
# This mechanism also allows non bash script to have access to the request through the
# environment.
function init_environment()
{
	# we set all the needed variables in the environment.
	# this is needed because we can't export associative arrays...

	# Public: Absolute path to the root of the website (canonical, no symlink)
	#
	# bootstrap/app.sh runs from the root, so we take the current directory. `server.sh`
	# computes it once and exports it, so this `realpath` fork only happens without it.
	#
	# Assigned apart from `declare`, whose zero return would hide a `realpath` failure from
	if [ -z "${ROOT:-}" ]; then
		declare -g ROOT
		ROOT=$(realpath .) || { log "FATAL: cannot canonicalize '$PWD'"; exit 1; }
	fi
	export ROOT
	# Public: The method of the request (one of GET, HEAD, POST and OPTIONS)
	declare -g REQUEST_METHOD=''
	# Public: The requested URL, always as a path (`*` alone for an asterisk-form `OPTIONS`)
	#
	# An absolute-form target (`GET http://host/path`, the form a proxy sends) is rewritten
	# by `read_request()` to the path it points at, and any other non-path target is a 400,
	# so scripts never see a scheme or a host.
	declare -g REQUEST_URL=''
	# Public: The HTTP version the client announced (`HTTP/1.0`, `HTTP/1.1`...)
	#
	# `read_request()` rejects anything that is not `HTTP/1.x` (400 when unparseable, 505
	# on another major version), so scripts only ever see 1.x here. The answer is always
	# in HTTP 1.1 (RFC 9112 §2.3 — the version in the response advertises capability, so
	# answering 1.1 to a 1.0 client is correct).
	declare -g REQUEST_HTTP_VERSION=''
	# Public: The headers from the request (associative array)
	#
	# The keys are lowercase, because HTTP header names are case insensitive:
	# use `REQUEST_HEADERS['content-type']`, not `REQUEST_HEADERS['Content-Type']`.
	#
	# A header the client repeated is here as the `v1, v2` list it stands for (RFC 9110 §5.2).
	# `Cookie` recombines on `; ` instead (RFC 9113 §8.2.3), and a repeated `Host`,
	# `Content-Length` or `Content-Type` with two different values is a 400.
	declare -Ag REQUEST_HEADERS
	# Public: Body of the request (mainly useful for POST)
	declare -g REQUEST_BODY=''
	# Public: parameters of the request, in case of POST with `application/x-www-form-urlencoded`
	# content
	#
	# filled through the nameref of `_parse_parameters`, which shellcheck can't see
	# shellcheck disable=SC2034
	declare -Ag REQUEST_BODY_PARAMETERS
	# Public: The base URL, without the query string if any
	declare -g URL_BASE=''
	# Public: The parameters of the query string if any (in an associative array)
	#
	# See `parse_url()`.
	#
	# filled through the nameref of `_parse_parameters`, which shellcheck can't see
	# shellcheck disable=SC2034
	declare -Ag URL_PARAMETERS
	# Public: The response headers (associative array)
	declare -Ag RESPONSE_HEADERS=(
		[Server]='Conch'
		[Connection]='close'
		[X-Content-Type-Options]='nosniff'
		[Cache-Control]='private, max-age=60'
		#[Cache-Control]='private, max-age=0, no-cache, no-store, must-revalidate'
	)
	# Public: Generic HTTP response code with their meaning (associative array)
	declare -rAg HTTP_RESPONSE=(
		[100]='Continue'
		[200]='OK'
		[206]='Partial Content'
		[301]='Moved Permanently'
		[302]='Found'
		[303]='See Other'
		[304]='Not Modified'
		[307]='Temporary Redirect'
		[308]='Permanent Redirect'
		[400]='Bad Request'
		[403]='Forbidden'
		[404]='Not Found'
		[405]='Method Not Allowed'
		[411]='Length Required'
		[413]='Content Too Large'
		[414]='URI Too Long'
		[416]='Range Not Satisfiable'
		[417]='Expectation Failed'
		[431]='Request Header Fields Too Large'
		[500]='Internal Server Error'
		[501]='Not Implemented'
		[505]='HTTP Version Not Supported'
	)
	# Public: The methods the server accepts, as an `Allow` header value
	#
	# `read_request()` tests the request method against it and sends it with its 405, and the
	# dispatcher answers `OPTIONS` with it, so adding a method here cannot leave a stale
	# `Allow` behind. A single script advertises its own list instead, `Allow` being a property
	# of the target resource and not of the server (RFC 9110 §10.2.1).
	declare -rg SUPPORTED_METHODS='GET, HEAD, POST, OPTIONS'
	# Public: Biggest request body we accept to read, in bytes
	#
	# The body ends up in `REQUEST_FULL_STRING`, which we export. Linux refuses to run a
	# command when a single environment string is bigger than 128 kio, so past that limit
	# every external command (`realpath`, `cat`...) fails and we can't answer at all.
	declare -rg MAX_BODY_SIZE=$((64 * 1024))
	# Public: Biggest request line + headers we accept to read, in characters
	#
	# They land in `REQUEST_FULL_STRING` too, so they share the 128 kio limit of
	# `MAX_BODY_SIZE`. 8 kio (what nginx and Apache use) leaves room for a full body even if
	# every header character takes 4 bytes.
	declare -rg MAX_HEADERS_SIZE=$((8 * 1024))
	# Internal: anchored regex matching a whole RFC 9110 §5.6.2 token
	#
	# Shared by the method check of `_read_request_line()` and the field name check of
	# `_read_request_headers()`: both are that one grammar rule, so they must not drift.
	# The ranges are spelled out because `[[:alnum:]]` follows the locale, and the
	# `LC_ALL=C.UTF-8` of the dispatcher would let every Unicode letter through.
	declare -rg _HTTP_TOKEN_REGEX=$'^[A-Za-z0-9!#$%&\'*+.^_`|~-]+$'
	# Internal: canonical path computed by `_resolve_path()`
	declare -g _RESOLVED_PATH=''
	# Internal: the request-target exactly as the client sent it
	#
	# The access log reads it instead of `REQUEST_URL`, which loses the absolute form to the
	# rewrite in `read_request()` — the log must keep proxy-style requests greppable.
	declare -g _REQUEST_TARGET=''
	# Internal: the validated authority of an absolute-form target, empty otherwise
	#
	# Filled by `_read_request_line()` when the target proves absolute-form, applied over
	# the `Host` header by `_read_request_headers()`.
	declare -g _REQUEST_AUTHORITY=''
	# Public: `true` when verbose logging is on, see `log_debug()`
	#
	# Read from the environment because that is the only channel that survives the exec into
	# a child script: `server.sh --debug` exports `DEBUG`, and so does `systemd`.
	declare -rg DEBUG_LOG="${DEBUG:-0}"

	# if REQUEST_FULL_STRING is empty, we fill it with the input stream and we export it
	if [ -z "$REQUEST_FULL_STRING" ]; then
		read_request true
		log_debug
		export REQUEST_FULL_STRING
	else
		read_request false <<< "$REQUEST_FULL_STRING"
	fi
}
export -f init_environment