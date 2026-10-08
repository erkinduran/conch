#!/bin/bash

set -efu

# mysql driver: `mysql --batch`, one row per line, fields separated by a tab, with `\n`,
# `\t`, `\\` and `\0` escaped in the values and NULL written as `NULL`.
#
# [untested against a live server: written from the documented `--batch` format]
declare -gr _DB_IDENT_QUOTE='`'
declare -gr _DB_LAST_ID_SQL='SELECT LAST_INSERT_ID()'
declare -gr _DB_ID_COLUMN='INT AUTO_INCREMENT PRIMARY KEY'

function _db_connect()
{
	# --force: go on after an error, so the marker is always reached
	# --unbuffered: flush after each statement, or the read would wait forever
	local -a args=(--batch --force --unbuffered --column-names --default-character-set=utf8mb4)
	if [ -n "$DB_HOST" ]; then args+=("--host=$DB_HOST"); fi
	if [ -n "$DB_PORT" ]; then args+=("--port=$DB_PORT"); fi
	if [ -n "$DB_USERNAME" ]; then args+=("--user=$DB_USERNAME"); fi
	# the environment, not `--password=`: the command line is public in `ps`
	if [ -n "$DB_PASSWORD" ]; then export MYSQL_PWD="$DB_PASSWORD"; fi
	coproc _DB_CO {
		mysql "${args[@]}" "$DB_DATABASE" 2>&1
	}
}

function _db_run()
{
	local sql="$1" line done=0
	while [[ "$sql" == *[\;[:space:]] ]]; do
		sql="${sql%?}"
	done
	_db_send "$sql;
SELECT '$_DB_MARK';" || return 1
	local -a lines=()
	while IFS= read -r -u "${_DB_CO[0]}" line; do
		if [ "$line" = "$_DB_MARK" ]; then
			# the marker's header; its value follows
			IFS= read -r -u "${_DB_CO[0]}" line || true
			done=1
			break
		fi
		lines+=("$line")
	done
	if [ "$done" != 1 ]; then
		DB_ERROR='the mysql client is gone'
		_DB_CONNECTED=0
		return 1
	fi
	_db_parse_lines "${lines[@]+"${lines[@]}"}"
}

# Turn the client's lines into DB_COLUMNS / DB_ROWS, or DB_ERROR
function _db_parse_lines()
{
	local line first=1
	for line in "$@"; do
		if [[ "$line" == ERROR\ * ]]; then
			DB_ERROR="${DB_ERROR:+$DB_ERROR
}$line"
		elif [ "$first" = 1 ]; then
			_db_set_columns "${line//$'\t'/$_DB_FS}"
			first=0
		else
			_db_unescape_row "$line"
		fi
	done
	[ -z "$DB_ERROR" ]
}

# Append one tab-separated line to DB_ROWS, its fields unescaped and NULL made empty
function _db_unescape_row()
{
	local rest="$1"$'\t' field record=''
	while [ -n "$rest" ]; do
		field="${rest%%$'\t'*}"
		rest="${rest#*$'\t'}"
		if [ "$field" = NULL ]; then
			field=''
		else
			# `\\` first, kept apart so its backslash is not taken for the start of `\n`
			field="${field//'\\'/$'\x01'}"
			field="${field//'\n'/$'\n'}"
			field="${field//'\t'/$'\t'}"
			field="${field//'\0'/}"
			field="${field//$'\x01'/\\}"
		fi
		record+="${record:+$_DB_FS}$field"
	done
	DB_ROWS+=("$record")
}

# mysql also reads backslash escapes in a literal (unless NO_BACKSLASH_ESCAPES is on)
function _db_escape()
{
	local q="'" v="${2//\\/\\\\}"
	printf -v "$1" '%s' "${v//$q/$q$q}"
}
