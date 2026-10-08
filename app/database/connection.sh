#!/bin/bash

set -efu

# The SQL connection: one client process (`sqlite3`, `mysql` or `psql`) per request, started
# as a coprocess by the first `db_query()` and kept until the request ends. That is one fork
# however many queries a request runs, and no `$(...)` anywhere: results are read from the
# coprocess with the `read` builtin.
#
# A driver (app/database/drivers/$DB_CONNECTION.sh) provides:
#
#    _db_connect           start the coprocess `_DB_CO`
#    _db_run SQL           run one statement, fill DB_COLUMNS / DB_ROWS, or DB_ERROR and return 1
#    _db_escape VAR VALUE  write VALUE into VAR, escaped for a '...' literal
#    _DB_IDENT_QUOTE       the identifier quote (`"` or "`")
#    _DB_LAST_ID_SQL       the statement giving the id of the row just inserted
#    _DB_ID_COLUMN         the column definition `{{ id }}` stands for in a migration

# Public: Run one SQL statement.
#
# On success `DB_COLUMNS` holds the column names and `DB_ROWS` one record per row, the
# values separated by `_DB_FS`: see `db_row()`. A statement without a result leaves both
# empty. On failure the message is in `DB_ERROR`, logged, and the function returns 1, so
# under `set -e` write `db_query '...' || return 1` (or `|| send_error 500`).
#
# Everything in the statement is sent as is: build it with `db_quote()` and `db_ident()`,
# never by pasting a request value. NULL comes back as an empty string.
#
# $1 - the statement, with or without the final `;`
#
# Examples
#
#    db_query "SELECT id, name FROM users WHERE id = $id" || return 1
#    db_row 0 user
function db_query()
{
	DB_COLUMNS=()
	DB_ROWS=()
	DB_ERROR=''
	if [ "$_DB_CONNECTED" != 1 ]; then
		db_connect || return 1
	fi
	if ! _db_run "$1"; then
		log_error "DB ERROR: $DB_ERROR"
		log_debug "  in: $1"
		return 1
	fi
}

# Public: Open the connection now rather than on the first query. Returns 1 on failure.
function db_connect()
{
	DB_ERROR=''
	if ! _db_connect; then
		DB_ERROR="cannot start the $DB_CONNECTION client"
		log_error "DB ERROR: $DB_ERROR"
		return 1
	fi
	_DB_CONNECTED=1
}

# Public: Copy one row of the last result into an associative array, by column name.
#
# $1 - the row index in `DB_ROWS`
# $2 - the name of a variable declared with `declare -A` (or `local -A`)
#
# Examples
#
#    local -A user
#    db_row 0 user
#    printf '%s\n' "${user[name]}"
function db_row()
{
	local -n __db_row="$2"
	local rest="${DB_ROWS[$1]}" i
	__db_row=()
	for (( i = 0; i < ${#DB_COLUMNS[@]}; i++ )); do
		__db_row[${DB_COLUMNS[i]}]="${rest%%"$_DB_FS"*}"
		rest="${rest#*"$_DB_FS"}"
	done
}

# Public: Write a value into a variable as a quoted SQL literal, for the configured driver.
#
# $1 - the name of the variable to write
# $2 - the value
#
# Examples
#
#    db_quote name "${URL_PARAMETERS[name]}"
#    db_query "SELECT * FROM users WHERE name = $name"
function db_quote()
{
	local __db_quoted
	_db_escape __db_quoted "$2"
	printf -v "$1" "'%s'" "$__db_quoted"
}

# Public: Write a table or column name into a variable, quoted. Returns 1 (and logs) when
# the name is not `[A-Za-z_][A-Za-z0-9_]*`: a name is never taken from the request.
#
# $1 - the name of the variable to write
# $2 - the identifier
function db_ident()
{
	if [[ ! "$2" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
		log_error "DB ERROR: invalid identifier '$2'"
		return 1
	fi
	printf -v "$1" '%s%s%s' "$_DB_IDENT_QUOTE" "$2" "$_DB_IDENT_QUOTE"
}

# Fill `DB_COLUMNS` from a header record (names separated by `_DB_FS`)
function _db_set_columns()
{
	local rest="$1$_DB_FS"
	DB_COLUMNS=()
	while [ -n "$rest" ]; do
		DB_COLUMNS+=("${rest%%"$_DB_FS"*}")
		rest="${rest#*"$_DB_FS"}"
	done
}

# Write one line to the coprocess, or mark the connection lost and return 1
function _db_send()
{
	if [ -z "${_DB_CO[1]:-}" ] || ! printf '%s\n' "$1" >&"${_DB_CO[1]}"; then
		DB_ERROR="the $DB_CONNECTION client is gone"
		_DB_CONNECTED=0
		return 1
	fi
}

# The default escaping: `'` doubled. mysql overrides it
function _db_escape()
{
	local q="'"
	printf -v "$1" '%s' "${2//$q/$q$q}"
}
