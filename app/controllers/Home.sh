#!/bin/bash

# GET /: the introduction page
function index()
{
	render 'home' 'title=Conch' "bash=${BASH_VERSION%%(*}" "driver=$DB_CONNECTION"
}

# GET /hello/{name}
function hello()
{
	# from the URL, so the client wrote it: escaped before it goes in the page
	local name
	html_escape_to name "${ROUTE_PARAMETERS[name]}"
	render 'hello' 'title=Merhaba' "name=$name"
}
