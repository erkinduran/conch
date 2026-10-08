#!/bin/bash

# The application: run once per connection by socat (see server.sh), from the root.
#
#    OPTIONS             answered for the whole server
#    /public/...         a static file from public/
#    anything else       the route groups of config/routes.sh

set -efu

source 'app/helpers.sh'

init_environment

source 'config/routes.sh'

function App()
{
	# answer OPTIONS for the whole server, before any path resolution: that is what makes the
	# asterisk-form `OPTIONS * HTTP/1.1` work, as `*` is no path and would only ever 404
	if [ "$REQUEST_METHOD" = 'OPTIONS' ]; then
		add_header 'Allow' "$SUPPORTED_METHODS"
		# 200 with an empty body and not 204: a 204 MUST NOT carry the `Content-Length`
		# that `send_response` adds to everything but a 304
		send_response 200
	# serve a static asset: `/public/venise.webp` is `./public/venise.webp`, confined there
	elif [[ $URL_BASE == /public/* ]]; then
		send_file "${URL_BASE:1}"
	# everything else goes through the routes: the files of the groups whose prefix the
	# path starts with are loaded, then the first matching route runs
	else
		load_route_groups
		dispatch_route
	fi
}

App

exit 0
