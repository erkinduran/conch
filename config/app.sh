#!/bin/bash

# Application settings. Each one is only a default: a value already in the environment
# wins, and `.env` sets them (see .env.example).

# local | development | production
: "${APP_ENV:=local}"

# What the server writes to its console (stderr, the journal under systemd):
#
#    debug  everything below, plus the full request and response dumps (`log_debug`)
#    info   one access line per response, and the reason of every 4xx (`log`)
#    error  server-side errors only: misconfiguration, database, Redis (`log_error`)
#    none   nothing
#
# By default `info`, and `error` in production. `server.sh --debug` makes it `debug`.
if [ -z "${LOG_LEVEL:-}" ]; then
	if [ "$APP_ENV" = production ]; then
		LOG_LEVEL=error
	else
		LOG_LEVEL=info
	fi
fi
if [ "${DEBUG:-0}" = 1 ]; then
	LOG_LEVEL=debug
fi
