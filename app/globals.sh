#!/bin/bash

# Top-level state shared by the helpers: every `declare -g` lives here, sourced by
# `app/helpers.sh` before the helper functions, so each of them finds its globals
# whatever order the files load in. The per-request variables (`REQUEST_METHOD`,
# `URL_BASE`, ...) are declared by `init_environment()` instead, as they are reset per
# request.

set -efu

# Public: The full request string
declare -g REQUEST_FULL_STRING=''

# Routes registered by `route()`, one entry per route in each of the four arrays
declare -ga _ROUTE_METHODS=() _ROUTE_PATHS=() _ROUTE_CONTROLLERS=() _ROUTE_ACTIONS=()
# Route groups declared by `route_group()` in config/routes.sh, and the prefix of the one
# whose file is being loaded
declare -ga _ROUTE_GROUP_PREFIXES=() _ROUTE_GROUP_FILES=()
declare -g _ROUTE_PREFIX=''

# Public: The `{name}` segments of the matched route, by name
#
# Examples
#
#    route GET '/users/{id}' 'Users' 'show'
#
# a request to `/users/42` gives `ROUTE_PARAMETERS[id]` = `42`
declare -gA ROUTE_PARAMETERS=()

# Database (see app/database/): the result of the last `db_query()`
declare -ga DB_COLUMNS=() DB_ROWS=()
# Public: The message of the last failed `db_query()`, empty after a successful one
declare -g DB_ERROR=''
# Record and field separators of the result rows: two control bytes no text contains
declare -gr _DB_FS=$'\x1f' _DB_RS=$'\x1e'
# The line the drivers print after each statement, to know where its output ends
declare -gr _DB_MARK='__CONCH_END_7f3a__'
declare -g _DB_CONNECTED=0

# Redis: the reply of the last `redis()` call
declare -g REDIS_TYPE='' REDIS_REPLY=''
declare -ga REDIS_ARRAY=()
declare -g _REDIS_FD=''

# Models registered by `model()`, by name
declare -gA _MODEL_TABLE=() _MODEL_KEY=() _MODEL_FILLABLE=()
# The query being built by `query()`, `where()`, `order_by()`...
declare -g _QB_MODEL='' _QB_WHERE='' _QB_ORDER='' _QB_LIMIT='' _QB_OFFSET='' _QB_SQL=''
