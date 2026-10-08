#!/bin/bash

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
		items+="<li><a href=\"/users/${user[id]}\">$name</a> &lt;$email&gt;</li>"
	done
	# a Redis counter; the page does without it when Redis is not there
	if redis INCR 'conch:users:visits'; then
		visits="$REDIS_REPLY"
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

# POST /users, from the form on /users
function store()
{
	local -A user
	if [ -z "${REQUEST_BODY_PARAMETERS[name]:-}" ] || [ -z "${REQUEST_BODY_PARAMETERS[email]:-}" ]; then
		send_error 400
	fi
	# only the fillable columns of `User` are copied from the form
	create User user REQUEST_BODY_PARAMETERS || send_error 500
	send_redirect "/users/${user[id]}" 303
}
