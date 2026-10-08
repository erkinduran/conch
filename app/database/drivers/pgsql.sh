#!/bin/bash

set -efu

# pgsql driver: `psql` in unaligned mode, records separated by `_DB_RS`, fields by `_DB_FS`
# (tested against PostgreSQL 17)
declare -gr _DB_IDENT_QUOTE='"'
declare -gr _DB_LAST_ID_SQL='SELECT lastval()'
declare -gr _DB_ID_COLUMN='SERIAL PRIMARY KEY'

function _db_connect()
{
	# -q: no command tags (`INSERT 0 1`), -X: no psqlrc, footer off: no `(3 rows)`
	local -a args=(-qAX -F "$_DB_FS" -R "$_DB_RS" -P footer=off -P null= -v ON_ERROR_STOP=0)
	if [ -n "$DB_HOST" ]; then args+=(-h "$DB_HOST"); fi
	if [ -n "$DB_PORT" ]; then args+=(-p "$DB_PORT"); fi
	if [ -n "$DB_USERNAME" ]; then args+=(-U "$DB_USERNAME"); fi
	if [ -n "$DB_PASSWORD" ]; then export PGPASSWORD="$DB_PASSWORD"; fi
	coproc _DB_CO {
		psql "${args[@]}" -d "$DB_DATABASE" 2>&1
	}
}

function _db_run()
{
	local sql="$1" line raw='' done=0
	while [[ "$sql" == *[\;[:space:]] ]]; do
		sql="${sql%?}"
	done
	_db_send "$sql;
\\echo $_DB_MARK" || return 1
	while IFS= read -r -u "${_DB_CO[0]}" line; do
		if [ "$line" = "$_DB_MARK" ]; then
			done=1
			break
		fi
		raw+="$line"$'\n'
	done
	if [ "$done" != 1 ]; then
		DB_ERROR='the psql client is gone'
		_DB_CONNECTED=0
		return 1
	fi
	_db_parse_raw "$raw"
}

# Turn the client's output into DB_COLUMNS / DB_ROWS, or DB_ERROR
function _db_parse_raw()
{
	# a table ends with a newline; the last record may or may not carry a separator too
	local raw="${1%$'\n'}"
	raw="${raw%"$_DB_RS"}"
	if [ -z "$raw" ]; then
		return 0
	fi
	if [[ "$raw" == ERROR:* || "$raw" == psql:* ]]; then
		DB_ERROR="$raw"
		return 1
	fi
	_db_set_columns "${raw%%"$_DB_RS"*}"
	if [[ "$raw" == *"$_DB_RS"* ]]; then
		raw="${raw#*"$_DB_RS"}$_DB_RS"
		while [ -n "$raw" ]; do
			DB_ROWS+=("${raw%%"$_DB_RS"*}")
			raw="${raw#*"$_DB_RS"}"
		done
	fi
}
