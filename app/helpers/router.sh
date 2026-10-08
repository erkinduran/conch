#!/bin/bash

set -efu

# Public: Declare a route group, to be called from `config/routes.sh`.
#
# The file is `source`d by `load_route_groups()` only when the request path is the prefix
# or starts with `prefix/`, and every `route` it calls gets the prefix in front of its path.
# A prefix with a `{name}` segment is loaded for every request, its routes matched as usual.
#
# $1 - the prefix: empty or `/` for none, else starting with `/` (a trailing `/` is dropped)
# $2 - the routes file, relative to the root
#
# Examples
#
#    route_group ''        'routes/web.sh'
#    route_group '/api/v2' 'routes/apiv2.sh'
function route_group()
{
	local prefix="${1%/}"
	if [ "$#" -ne 2 ] || { [ -n "$prefix" ] && [[ $prefix != /* ]]; }; then
		log "MISCONFIGURED: route_group wants /prefix file, got '$*'"
		send_error 500
	fi
	_ROUTE_GROUP_PREFIXES+=("$prefix")
	_ROUTE_GROUP_FILES+=("$2")
}
export -f route_group

# Public: Load the route files of the groups the request path falls in, the longest prefix
# first so its routes win over a shorter prefix's. Called by bootstrap/app.sh.
function load_route_groups()
{
	local -a order=()
	local prefix file
	local -i i j
	for (( i = 0; i < ${#_ROUTE_GROUP_PREFIXES[@]}; i++ )); do
		prefix="${_ROUTE_GROUP_PREFIXES[i]}"
		if [ -n "$prefix" ] && [[ $prefix != *'{'* ]] &&
			[ "$URL_BASE" != "$prefix" ] && [[ $URL_BASE != "$prefix"/* ]]; then
			continue
		fi
		# insertion by prefix length, longest first: a handful of groups, no `sort` fork
		for (( j = ${#order[@]}; j > 0; j-- )); do
			[ "${#_ROUTE_GROUP_PREFIXES[order[j-1]]}" -lt "${#prefix}" ] || break
			order[j]="${order[j-1]}"
		done
		order[j]="$i"
	done
	for i in "${order[@]+"${order[@]}"}"; do
		file="${_ROUTE_GROUP_FILES[i]}"
		if [ ! -f "$file" ]; then
			log "MISCONFIGURED: routes file '$file' not found (config/routes.sh)"
			send_error 500
		fi
		_ROUTE_PREFIX="${_ROUTE_GROUP_PREFIXES[i]}"
		source "$file"
	done
	_ROUTE_PREFIX=''
}
export -f load_route_groups

# Public: Register a route, to be called from a routes file (see `route_group()`).
#
# The path gets the prefix of the group whose file is being loaded. It is matched against
# `URL_BASE` (the query string is not part of it), a trailing `/` ignored on both sides. A `{name}` segment matches any one non-empty segment, which
# then lands in `ROUTE_PARAMETERS[name]`. Routes are tried in order, the first match wins.
#
# The action runs inside the dispatcher's process: the controller is `source`d, so it has
# every variable and function of the helpers at hand, and costs no fork.
#
# A `GET` route also answers `HEAD`.
#
# $1 - HTTP method (`GET` or `POST`)
# $2 - path, starting with `/`
# $3 - controller, `app/controllers/$3.sh` (`Api/Users` is `app/controllers/Api/Users.sh`)
# $4 - action, a function that controller defines; it must send a response
#
# Examples
#
#    route GET  '/'           'Home'  'index'
#    route GET  '/users/{id}' 'Users' 'show'
#    route POST '/users'      'Users' 'store'
function route()
{
	if [ "$#" -ne 4 ] || [[ $2 != /* ]]; then
		log "MISCONFIGURED: route wants METHOD /path Controller action, got '$*'"
		send_error 500
	fi
	_ROUTE_METHODS+=("$1")
	_ROUTE_PATHS+=("$_ROUTE_PREFIX$2")
	_ROUTE_CONTROLLERS+=("$3")
	_ROUTE_ACTIONS+=("$4")
}
export -f route

# Internal: Tell whether the path matches the route pattern, filling `ROUTE_PARAMETERS`.
#
# Both come without their trailing `/` (but `/` itself), see `dispatch_route()`.
#
# $1 - route pattern, like `/users/{id}`
# $2 - requested path, like `/users/42`
function _match_route()
{
	ROUTE_PARAMETERS=()
	# no placeholder: a plain comparison, the common case
	if [[ $1 != *'{'* ]]; then
		[ "$1" = "$2" ]
		return
	fi
	local -a pattern_segments path_segments
	IFS='/' read -r -a pattern_segments <<< "$1"
	IFS='/' read -r -a path_segments <<< "$2"
	[ "${#pattern_segments[@]}" -eq "${#path_segments[@]}" ] || return 1
	local -i i
	for (( i = 0; i < ${#pattern_segments[@]}; i++ )); do
		if [[ ${pattern_segments[i]} == '{'?*'}' ]]; then
			# `/users//` is no `/users/{id}`
			[ -n "${path_segments[i]}" ] || return 1
			ROUTE_PARAMETERS[${pattern_segments[i]:1:-1}]="${path_segments[i]}"
		elif [ "${pattern_segments[i]}" != "${path_segments[i]}" ]; then
			return 1
		fi
	done
}
export -f _match_route

# Public: Run the action of the route matching the request, or answer 404 or 405.
#
# A path that some route matches with another method is a 405, with the `Allow` header
# listing the methods that path does take.
#
# The action must end the process by sending a response (`render`, `send_response`...):
# one that returns is a bug in the controller, answered with a 500.
function dispatch_route()
{
	# HEAD is answered by the GET route: `send_response` already drops the body
	local -r method="${REQUEST_METHOD/#HEAD/GET}"
	local path="$URL_BASE" pattern allowed='' file action
	[ "$path" = '/' ] || path="${path%/}"
	local -i i
	for (( i = 0; i < ${#_ROUTE_PATHS[@]}; i++ )); do
		pattern="${_ROUTE_PATHS[i]}"
		[ "$pattern" = '/' ] || pattern="${pattern%/}"
		_match_route "$pattern" "$path" || continue
		if [ "${_ROUTE_METHODS[i]}" != "$method" ]; then
			allowed+="${allowed:+, }${_ROUTE_METHODS[i]}"
			continue
		fi
		file="$ROOT/app/controllers/${_ROUTE_CONTROLLERS[i]}.sh"
		action="${_ROUTE_ACTIONS[i]}"
		if [ ! -f "$file" ]; then
			log "MISCONFIGURED: controller '$file' not found"
			send_error 500
		fi
		source "$file"
		# `declare -F` and not `type`: an external command named like the action must not do
		if ! declare -F "$action" > /dev/null; then
			log "MISCONFIGURED: '$file' defines no '$action' function"
			send_error 500
		fi
		"$action"
		log "MISCONFIGURED: '${_ROUTE_CONTROLLERS[i]} $action' returned without a response"
		send_error 500
	done
	if [ -n "$allowed" ]; then
		[[ ", $allowed," != *', GET,'* ]] || allowed+=', HEAD'
		add_header 'Allow' "$allowed, OPTIONS"
		send_error 405
	fi
	log "NOT FOUND: no route for $REQUEST_METHOD '$URL_BASE'"
	send_error 404
}
export -f dispatch_route
