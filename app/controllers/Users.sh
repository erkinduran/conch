#!/bin/bash

# A read-only example: the users come from the seed migration, the site takes no input.
# `create User user REQUEST_BODY_PARAMETERS` is how a form would add one (see README).

# GET /users
function index()
{
	local -a users
	local -A user
	local record items='' name email visits=''
	query User || send_error 500
	order_by name || send_error 500
	get users || send_error 500
	for record in "${users[@]+"${users[@]}"}"; do
		row user "$record"
		html_escape_to name "${user[name]}"
		html_escape_to email "${user[email]}"
		items+="<li><a href=\"/users/${user[id]}\">$name</a> <span>$email</span></li>"
	done
	# a Redis counter, shown only when Redis is there
	if redis INCR 'conch:users:visits'; then
		visits="<p class=\"visits\">Bu sayfa $REDIS_REPLY kez görüntülendi (Redis).</p>"
	fi
	render 'users' 'title=Kullanıcılar' "count=${#users[@]}" "items=$items" "visits=$visits"
}

# GET /users/{id}
function show()
{
	local -A user
	local name email
	find User "${ROUTE_PARAMETERS[id]}" user || send_error 404
	html_escape_to name "${user[name]}"
	html_escape_to email "${user[email]}"
	render 'user' "title=$name" "id=${user[id]}" "name=$name" "email=$email"
}
