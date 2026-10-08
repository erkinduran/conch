#!/bin/bash

set -efu

# sqlite driver: `sqlite3 -batch`, rows ending with `_DB_RS`, fields with `_DB_FS`
declare -gr _DB_IDENT_QUOTE='"'
declare -gr _DB_LAST_ID_SQL='SELECT last_insert_rowid()'
declare -gr _DB_ID_COLUMN='INTEGER PRIMARY KEY AUTOINCREMENT'

function _db_connect()
{
	# stderr merged: an error shows up where its statement's rows would, ending with a
	# newline where a row ends with `_DB_RS`, which is how `_db_run` tells them apart
	coproc _DB_CO {
		sqlite3 -batch -header -separator "$_DB_FS" -newline "$_DB_RS" -nullvalue '' "$DB_DATABASE" 2>&1
	}
}

function _db_run()
{
	local sql="$1" seg err='' done=0
	# our own `;` must not follow one already there: `;;` is an empty statement
	while [[ "$sql" == *[\;[:space:]] ]]; do
		sql="${sql%?}"
	done
	# the marker is a statement too, so it runs (and ends the read) even after an error
	_db_send "$sql;
SELECT '$_DB_MARK' AS \"$_DB_MARK\";" || return 1
	local -a segs=()
	while IFS= read -r -d "$_DB_RS" -u "${_DB_CO[0]}" seg; do
		if [[ "$seg" == *"$_DB_MARK" ]]; then
			# anything before the marker's header is an error message
			err="${seg%"$_DB_MARK"}"
			# the marker's one value
			IFS= read -r -d "$_DB_RS" -u "${_DB_CO[0]}" seg || true
			done=1
			break
		fi
		segs+=("$seg")
	done
	if [ "$done" != 1 ]; then
		DB_ERROR='the sqlite3 client is gone'
		_DB_CONNECTED=0
		return 1
	fi
	if [ -n "$err" ]; then
		DB_ERROR="${err%$'\n'}"
		return 1
	fi
	if [ "${#segs[@]}" -gt 0 ]; then
		_db_set_columns "${segs[0]}"
		if [ "${#segs[@]}" -gt 1 ]; then
			DB_ROWS=("${segs[@]:1}")
		fi
	fi
}
