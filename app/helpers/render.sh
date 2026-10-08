#!/bin/bash

set -efu

# Public: Send `resources/views/$1.html` as the answer, each `{{ key }}` replaced by its value.
#
# Values are inserted as is: `html_escape` anything that comes from the request first.
# A `{{ key }}` no pair names is left in the page.
#
# $1  - view name, without `.html`
# $2… - `key=value` pairs
#
# Examples
#
#    render 'home' 'title=Home' "name=$(html_escape "${URL_PARAMETERS[name]:-}")"
function render()
{
	local -r file="$ROOT/resources/views/$1.html"
	shift
	if [ ! -f "$file" ]; then
		log "MISCONFIGURED: view '$file' not found"
		send_error 500
	fi
	local html='' pair
	# no fork, unlike `$(cat)` or `envsubst`; `read` returns 1 on reaching the end of file
	IFS= read -r -d '' html < "$file" || true
	for pair in "$@"; do
		# both sides quoted: the key is matched literally, and a `&` in the value stays a `&`
		html="${html//"{{ ${pair%%=*} }}"/"${pair#*=}"}"
	done
	add_header 'Content-Type' 'text/html; charset=utf-8'
	send_response 200 "$html"
}
export -f render
