#!/bin/bash

set -efu

# Internal: Tell if the given string is properly percent encoded.
#
# **Note:** this method is used by `read_request()` and shouldn't be called manually.
#
# Returns 0 if the string can safely be given to `_url_decode()`, 1 otherwise. A `%` that
# is not followed by 2 hexadecimal digits can't be decoded, and `%00` decodes to a NUL
# byte, which silently truncates the string in bash.
#
# $1 - the string to check
function _check_encoding()
{
	if [[ $1 == *%00* ]]; then
		return 1
	fi
	# a regex stays linear, where `${1//%[hex][hex]/}` copies the string once per match
	local -r broken='%([^0-9a-fA-F]|[0-9a-fA-F][^0-9a-fA-F]|[0-9a-fA-F]?$)'
	# no `%` outside of a valid triplet means the whole string is decodable
	! [[ $1 =~ $broken ]]
}
export -f _check_encoding

# Internal: Decode the percent encoded characters of the given string.
#
# **Note:** the string must have been accepted by `_check_encoding()` first.
#
# The result is stored in the variable named by the first parameter, because a command
# substitution would drop a trailing newline coming from a `%0A`.
#
# $1 - name of the variable to store the result in
# $2 - the string to decode
#
# Examples
#
#    _url_decode value 'caf%C3%A9'
#
# will result in
#
#    value='café'
function _url_decode()
{
	# a backslash already in the string would be interpreted, so we double it first
	local -r escaped="${2//\\/\\\\}"
	printf -v "$1" '%b' "${escaped//%/\\x}"
}
export -f _url_decode

# Internal: Fill an associative array from a string of urlencoded parameters.
#
# **Note:** this method is used by `parse_url()` and `_read_request_body()` and shouldn't
# be called manually.
#
# Takes the `key=value` pairs joined by `&` that a query string and an urlencoded body
# share, decodes both sides, and stores them in the array named by the second parameter.
# The array is emptied first, so a second parse never keeps keys from the first one.
# The string must have been accepted by `_check_encoding()` first.
#
# A parameter without a name is skipped, as an empty key is not a valid array subscript.
# A `+` decodes to a space, in the query string and in a form body both.
#
# $1 - the urlencoded parameters (`key=value` pairs joined by `&`)
# $2 - name of the associative array to fill
#
# Examples
#
#    _parse_parameters 'test=youpi&city=caf%C3%A9+ville' 'URL_PARAMETERS'
#
# will result in
#
#    URL_PARAMETERS=(
#        ['test']='youpi'
#        ['city']='café ville'
#    )
function _parse_parameters()
{
	# a nameref, because the two callers fill two different arrays
	local -n _parameters=$2
	# a child script may call `parse_url` on a second URL: keys must not accumulate
	_parameters=()
	# first, split `key=value` in an array
	local -a fields
	IFS='&' read -ra fields <<< "$1"
	local key value
	local -i i
	for (( i=0; i < ${#fields[@]}; i++ )); do
		IFS='=' read -r key value <<< "${fields[i]}"
		# an empty key is a fatal `bad array subscript`, and carries no information anyway
		if [ -z "$key" ]; then
			continue
		fi
		# `+` is a space in urlencoded content
		_url_decode key "${key//+/ }"
		_url_decode value "${value//+/ }"
		_parameters["$key"]="$value"
	done
}
export -f _parse_parameters

# Public: Parse the given URL to exrtact the base URL and the query string.
#
# Takes an optional parameters: the URL to parse. By default, it will take the content of
# the variable `REQUEST_URL`.
#
# It will store the base of the URL (without query string) in `URL_BASE`.
# It will store all the parameters of the query string in the associative array `URL_PARAMETERS`.
#
# Everything is percent decoded, but only once the URL has been split: a `%3F` in the path
# is a question mark in a file name, not the start of the query string. A URL that is not
# properly percent encoded can't be decoded, and is answered with a 400.
#
# A parameter without a name is skipped, as an empty key is not a valid array subscript.
#
# $1 - Optional: URL to parse (default will take content of `REQUEST_URL`)
#
# Examples
#
#    parse_url '/index.sh?test=youpi&answer=42&city=caf%C3%A9+ville'
#
# will result in
#
#    URL_BASE='/index.sh'
#    URL_PARAMETERS=(
#        ['test']='youpi'
#        ['answer']='42'
#        ['city']='café ville'
#    )
function parse_url()
{
	local -r url="${1:-$REQUEST_URL}"
	# `read_request()` already checked the request URL, but this function is public
	if ! _check_encoding "$url"; then
		log "BAD REQUEST: invalid percent encoding in '$url'"
		send_error 400
	fi
	# get base URL and parameters
	local parameters
	IFS='?' read -r URL_BASE parameters <<< "$url"
	# a `+` stays a `+` in the path: the space treatment belongs to the parameters only
	_url_decode URL_BASE "$URL_BASE"
	_parse_parameters "$parameters" 'URL_PARAMETERS'
}
export -f parse_url
