#!/bin/bash

set -efu

# JSON: build values into variables (no `$(...)`, so no subshell), then send one with
# `json`, the counterpart of `render` for an API.
#
#    json_string  VAR value            a string literal, escaped
#    json_object  VAR key=value ...    an object; `key:=raw` for a number, true, null, nested JSON
#    json_array   VAR item ...         an array of raw JSON items
#    json_record  VAR RECORD [col ...] a model record (`find`, `first`) as an object
#    json_collection VAR ROWS [col ...] a `get` / `all` collection as an array of objects
#    json         BODY [status]        send BODY as `application/json`, 200 by default
#
# In `json_record` and `json_collection` a column is a string unless written `col:=`, then
# its value goes in as is: `id:=` for a number. Without columns, every column is a string.
#
# Examples
#
#    find User "$id" user || json_error 404 'not found'
#    json_record body user 'id:=' name email
#    json "$body"
#
#    all User users
#    json_collection body users 'id:=' name email
#    json "$body"
#
#    json_object body 'ok:=true' "name=$name" 'count:=3'
#    json "$body" 201

# Public: A JSON string literal, quotes included, into a variable.
#
# `\` and `"` are escaped, and every control character: `\n`, `\r`, `\t` by name, the
# others as `\u00XX`. The rest of the text, UTF-8 included, is written as is.
#
# $1 - the name of the variable to write
# $2 - the string
function json_string()
{
	# `__json_*` locals: one named like the variable in $1 would get the result instead
	local __json_s="${2//\\/\\\\}"
	__json_s="${__json_s//\"/\\\"}"
	__json_s="${__json_s//$'\n'/\\n}"
	__json_s="${__json_s//$'\r'/\\r}"
	__json_s="${__json_s//$'\t'/\\t}"
	# the rare other control characters, one by one; skipped when there are none
	if [[ "$__json_s" == *[$'\001'-$'\037'$'\177']* ]]; then
		local __json_out='' __json_c __json_code
		local -i __json_i
		for (( __json_i = 0; __json_i < ${#__json_s}; __json_i++ )); do
			__json_c="${__json_s:__json_i:1}"
			if [[ "$__json_c" == [$'\001'-$'\037'$'\177'] ]]; then
				printf -v __json_code '\\u%04x' "'$__json_c"
				__json_out+="$__json_code"
			else
				__json_out+="$__json_c"
			fi
		done
		__json_s="$__json_out"
	fi
	printf -v "$1" '"%s"' "$__json_s"
}
export -f json_string

# Public: A JSON object from `key=value` pairs (string values) and `key:=raw` pairs (the
# value is JSON already: a number, `true`, `null`, an object built before...).
#
# $1  - the name of the variable to write
# $2… - the pairs, in the order they are written
function json_object()
{
	local __json_name="$1" __json_body='' __json_pair __json_key __json_value
	shift
	for __json_pair in "$@"; do
		if [[ "$__json_pair" == *:=* && "${__json_pair%%:=*}" != *=* ]]; then
			json_string __json_key "${__json_pair%%:=*}"
			__json_value="${__json_pair#*:=}"
		else
			json_string __json_key "${__json_pair%%=*}"
			json_string __json_value "${__json_pair#*=}"
		fi
		__json_body+="${__json_body:+,}$__json_key:$__json_value"
	done
	printf -v "$__json_name" '{%s}' "$__json_body"
}
export -f json_object

# Public: A JSON array of raw JSON items (each built with `json_string`, `json_object`...).
#
# $1  - the name of the variable to write
# $2… - the items
function json_array()
{
	local __json_name="$1" __json_body='' __json_item
	shift
	for __json_item in "$@"; do
		__json_body+="${__json_body:+,}$__json_item"
	done
	printf -v "$__json_name" '[%s]' "$__json_body"
}
export -f json_array

# Public: A model record (an associative array from `find`, `first`, `row`) as an object.
#
# $1  - the name of the variable to write
# $2  - the name of the record
# $3… - Optional: the columns, in order; `col:=` for a raw value (a number). Without them,
#       every column but `_model`, as strings, in no particular order.
function json_record()
{
	local -n __json_record="$2"
	local __json_name="$1" __json_column __json_key
	local -a __json_pairs=()
	shift 2
	if [ $# -eq 0 ]; then
		for __json_column in "${!__json_record[@]}"; do
			[ "$__json_column" = _model ] || set -- "$@" "$__json_column"
		done
	fi
	for __json_column in "$@"; do
		__json_key="${__json_column%:=}"
		if [ ! -v "__json_record[$__json_key]" ]; then
			log_error "MISCONFIGURED: json_record: no column '$__json_key'"
			return 1
		fi
		if [ "$__json_key" != "$__json_column" ]; then
			# a raw value that is empty (a NULL from the database) is no JSON: null
			__json_pairs+=("$__json_key:=${__json_record[$__json_key]:-null}")
		else
			__json_pairs+=("$__json_key=${__json_record[$__json_key]}")
		fi
	done
	json_object "$__json_name" "${__json_pairs[@]+"${__json_pairs[@]}"}"
}
export -f json_record

# Public: A collection (the indexed array of `get` or `all`) as an array of objects.
#
# $1  - the name of the variable to write
# $2  - the name of the collection
# $3… - Optional: the columns, as for `json_record()`
function json_collection()
{
	local -n __json_rows="$2"
	local __json_name="$1" __json_row_item __json_body=''
	local -A __json_row
	shift 2
	for __json_row_item in "${__json_rows[@]+"${__json_rows[@]}"}"; do
		row __json_row "$__json_row_item"
		json_record __json_row_item __json_row "$@" || return 1
		__json_body+="${__json_body:+,}$__json_row_item"
	done
	printf -v "$__json_name" '[%s]' "$__json_body"
}
export -f json_collection

# Public: Send a JSON body as the answer, like `render` does for a view.
#
# $1 - the body, JSON already (built with the functions above)
# $2 - Optional: the status code, 200 by default
#
# Examples
#
#    json '{"ok":true}'
#    json "$body" 201
function json()
{
	add_header 'Content-Type' 'application/json; charset=utf-8'
	send_response "${2:-200}" "$1"
}
export -f json

# Public: Send `{"error": message}` with an error status, for an API route where the HTML
# page of `send_error` would be of no use to the client.
#
# $1 - the status code
# $2 - Optional: the message, the status' reason phrase by default
#
# Examples
#
#    find User "$id" user || json_error 404 'user not found'
function json_error()
{
	# not `__json_body`: `json_object` has a local of that name, which would get the result
	local __json_error_body
	json_object __json_error_body "error=${2:-${HTTP_RESPONSE[$1]:-error}}"
	json "$__json_error_body" "$1"
}
export -f json_error
