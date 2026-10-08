#!/bin/bash

set -efu

# Public: Print the given string with the HTML special characters escaped.
#
# Everything coming from the request (the URL, its parameters, the headers, the body...) is
# written by the client. A script that drops it in a page as is lets that client inject its
# own markup, so escape it, always. Best done at the point where the value is inserted, so
# that no unescaped copy is left around to be used by mistake.
#
# The 5 escaped characters cover text inside an element and the value of a quoted attribute.
# An unquoted attribute, a `<script>` or a `<style>` need more than this, and are a bad place
# to put anything the client sent in the first place.
#
# $1 - the string to escape
#
# Examples
#
#    html_escape '<script>alert(1)</script>'
#
# will print
#
#    &lt;script&gt;alert(1)&lt;/script&gt;
function html_escape()
{
	local escaped
	html_escape_to escaped "$1"
	printf '%s\n' "$escaped"
}
export -f html_escape

# Public: Same as `html_escape()`, into a variable: no `$(...)`, so no subshell.
#
# $1 - the name of the variable to write
# $2 - the string to escape
#
# Examples
#
#    html_escape_to name "${user[name]}"
function html_escape_to()
{
	# a name no caller uses: a local named like the variable in $1 would get the result
	# instead of it, `printf -v` writing to the innermost one
	#
	# `&` first, or we would escape the `&` of the entities added below. The `\&` are
	# mandatory: since bash 5.2, a bare `&` in a replacement means the matched text
	local __html_escaped="${2//&/\&amp;}"
	__html_escaped="${__html_escaped//</\&lt;}"
	__html_escaped="${__html_escaped//>/\&gt;}"
	__html_escaped="${__html_escaped//\"/\&quot;}"
	__html_escaped="${__html_escaped//\'/\&#39;}"
	printf -v "$1" '%s' "$__html_escaped"
}
export -f html_escape_to
