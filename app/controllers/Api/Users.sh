#!/bin/bash

# GET /api/users
function index()
{
	local -a users
	local body
	query User || json_error 500
	order_by id || json_error 500
	get users || json_error 500
	json_collection body users 'id:=' name email || json_error 500
	json "$body"
}

# GET /api/users/{id}
function show()
{
	local -A user
	local body
	find User "${ROUTE_PARAMETERS[id]}" user || json_error 404 'user not found'
	json_record body user 'id:=' name email || json_error 500
	json "$body"
}
