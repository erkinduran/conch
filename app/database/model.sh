#!/bin/bash

set -efu

# Models, in the active record style. A model is a name bound to a table; a record is an associative
# array holding one row plus `[_model]`, the model's name, so `save()` and `delete()` know
# the table; a collection is an indexed array of records, each serialised as one string,
# that `row()` turns back into an associative array.
#
# Define a model in app/models/Name.sh:
#
#    model User users id name email
#
# Read:
#
#    local -A user; local -a users
#    find User 42 user || send_error 404
#    all User users
#    query User; where status active; where age '>' 18; order_by name; limit 10; get users
#    query User; where email "$email"; first user || ...
#    query User; count n
#
# Write:
#
#    new User user; user[name]='Ayşe'; save user     # INSERT, user[id] is set
#    user[name]='Ayşe T.'; save user                 # UPDATE
#    create User user REQUEST_BODY_PARAMETERS        # new + fill (fillable only) + save
#    delete user
#
# Every function returns 1 on a database error (logged, message in `DB_ERROR`) and
# `find`, `first` also when nothing matches: under `set -e`, always write `|| ...`.
# Column and table names go through `db_ident()`, values through `db_quote()`: a `where`
# value may come straight from the request, a column name never.
#
# Note: `find` shadows the `find` command inside the dispatcher (which never forks it).

# Public: Register a model.
#
# $1  - the model name
# $2  - the table
# $3  - Optional: the primary key, `id` by default
# $4… - Optional: the fillable columns, the only ones `fill()` and `create()` copy
function model()
{
	_MODEL_TABLE[$1]="$2"
	_MODEL_KEY[$1]="${3:-id}"
	if [ $# -gt 3 ]; then
		_MODEL_FILLABLE[$1]="${*:4}"
	else
		_MODEL_FILLABLE[$1]=''
	fi
}

function _model_check()
{
	if [ ! -v "_MODEL_TABLE[$1]" ]; then
		log_error "MISCONFIGURED: no model '$1' (define it in app/models/)"
		return 1
	fi
}

# Public: Start a query on a model. Follow with `where()`, `order_by()`, `limit()`,
# `offset()` as needed, then `get()`, `first()` or `count()`.
function query()
{
	_model_check "$1" || return 1
	_QB_MODEL="$1"
	_QB_WHERE=''
	_QB_ORDER=''
	_QB_LIMIT=''
	_QB_OFFSET=''
}

# Public: Add a condition, joined with AND. `where col value` means `col = value`.
#
# $1 - the column
# $2 - the operator (=, !=, <>, <, <=, >, >=, LIKE, NOT LIKE), or the value
# $3 - the value, when an operator is given
function where()
{
	_qb_where AND "$@"
}

# Public: Same as `where()`, joined with OR.
function or_where()
{
	_qb_where OR "$@"
}

# Public: `where col IS NULL` / `IS NOT NULL`
function where_null()
{
	local ident
	db_ident ident "$1" || return 1
	_QB_WHERE+="${_QB_WHERE:+ AND }$ident IS NULL"
}

function where_not_null()
{
	local ident
	db_ident ident "$1" || return 1
	_QB_WHERE+="${_QB_WHERE:+ AND }$ident IS NOT NULL"
}

# Public: Add a condition written in SQL, joined with AND. Quote its values yourself.
function where_raw()
{
	_QB_WHERE+="${_QB_WHERE:+ AND }($1)"
}

function _qb_where()
{
	local glue="$1" column operator value ident quoted
	shift
	if [ $# -eq 2 ]; then
		column="$1"; operator='='; value="$2"
	else
		column="$1"; operator="${2^^}"; value="$3"
	fi
	case "$operator" in
		'='|'!='|'<>'|'<'|'<='|'>'|'>='|'LIKE'|'NOT LIKE') ;;
		*)	log_error "DB ERROR: unsupported operator '$2'"
			return 1 ;;
	esac
	db_ident ident "$column" || return 1
	db_quote quoted "$value"
	_QB_WHERE+="${_QB_WHERE:+ $glue }$ident $operator $quoted"
}

# Public: Sort. $1 the column, $2 `asc` (default) or `desc`. Call again for a second key.
function order_by()
{
	local ident direction="${2:-asc}"
	db_ident ident "$1" || return 1
	direction="${direction^^}"
	if [ "$direction" != ASC ] && [ "$direction" != DESC ]; then
		log_error "DB ERROR: bad sort direction '$2'"
		return 1
	fi
	_QB_ORDER+="${_QB_ORDER:+, }$ident $direction"
}

function limit()
{
	_qb_number _QB_LIMIT "$1"
}

function offset()
{
	_qb_number _QB_OFFSET "$1"
}

function _qb_number()
{
	if [[ ! "$2" =~ ^[0-9]+$ ]]; then
		log_error "DB ERROR: '$2' is not a number"
		return 1
	fi
	printf -v "$1" '%s' "$2"
}

# Write the SELECT for the current builder into `_QB_SQL`; $1 is the select list
function _qb_sql()
{
	local table
	db_ident table "${_MODEL_TABLE[$_QB_MODEL]}" || return 1
	_QB_SQL="SELECT $1 FROM $table"
	_QB_SQL+="${_QB_WHERE:+ WHERE $_QB_WHERE}"
	_QB_SQL+="${_QB_ORDER:+ ORDER BY $_QB_ORDER}"
	_QB_SQL+="${_QB_LIMIT:+ LIMIT $_QB_LIMIT}"
	_QB_SQL+="${_QB_OFFSET:+ OFFSET $_QB_OFFSET}"
}

# Public: Run the query, one serialised record per row into an indexed array.
#
# $1 - the name of a variable declared with `declare -a` (or `local -a`)
#
# Examples
#
#    local -a users; local -A user; local record
#    query User; order_by name; get users || return 1
#    for record in "${users[@]}"; do
#        row user "$record"
#        printf '%s\n' "${user[name]}"
#    done
function get()
{
	local -n __get_rows="$1"
	local i j record rest
	__get_rows=()
	_qb_sql '*' || return 1
	db_query "$_QB_SQL" || return 1
	for (( i = 0; i < ${#DB_ROWS[@]}; i++ )); do
		rest="${DB_ROWS[i]}"
		record="_model=$_QB_MODEL"
		for (( j = 0; j < ${#DB_COLUMNS[@]}; j++ )); do
			record+="$_DB_FS${DB_COLUMNS[j]}=${rest%%"$_DB_FS"*}"
			rest="${rest#*"$_DB_FS"}"
		done
		__get_rows+=("$record")
	done
}

# Public: Turn one serialised record (an item of a `get()` collection) into an associative
# array: `row user "${users[0]}"`.
function row()
{
	local -n __row="$1"
	local rest="$2$_DB_FS" pair
	__row=()
	while [ -n "$rest" ]; do
		pair="${rest%%"$_DB_FS"*}"
		rest="${rest#*"$_DB_FS"}"
		__row[${pair%%=*}]="${pair#*=}"
	done
}

# Public: Run the query for its first row, into an associative array. Returns 1 when
# there is none.
function first()
{
	local -a __first_rows
	_QB_LIMIT=1
	get __first_rows || return 1
	if [ "${#__first_rows[@]}" -eq 0 ]; then
		return 1
	fi
	row "$1" "${__first_rows[0]}"
}

# Public: Run the query for its row count, into a variable: `count n`
function count()
{
	_qb_sql 'COUNT(*) AS n' || return 1
	db_query "$_QB_SQL" || return 1
	printf -v "$1" '%s' "${DB_ROWS[0]}"
}

# Public: The record with the given primary key, into an associative array. Returns 1
# when there is none: `find User "$id" user || send_error 404`
function find()
{
	query "$1" || return 1
	where "${_MODEL_KEY[$1]}" "$2" || return 1
	first "$3"
}

# Public: Every record of a model, into an indexed array: `all User users`
function all()
{
	query "$1" || return 1
	get "$2"
}

# Public: An empty record of a model, into an associative array: `new User user`
function new()
{
	local -n __new="$2"
	_model_check "$1" || return 1
	__new=([_model]="$1")
}

# Public: Copy the fillable columns of the model from one associative array into a
# record, ignoring every other key: `fill user REQUEST_BODY_PARAMETERS`
function fill()
{
	local -n __fill_record="$1" __fill_source="$2"
	local column
	for column in ${_MODEL_FILLABLE[${__fill_record[_model]}]}; do
		if [ -v "__fill_source[$column]" ]; then
			__fill_record[$column]="${__fill_source[$column]}"
		fi
	done
}

# Public: INSERT a record without a primary key value, UPDATE one with. After an INSERT
# the key is filled in.
function save()
{
	local -n __save="$1"
	local model="${__save[_model]}" key table ident quoted column
	local columns='' values='' sets=''
	key="${_MODEL_KEY[$model]}"
	db_ident table "${_MODEL_TABLE[$model]}" || return 1
	for column in "${!__save[@]}"; do
		if [ "$column" = _model ] || [ "$column" = "$key" ]; then
			continue
		fi
		db_ident ident "$column" || return 1
		db_quote quoted "${__save[$column]}"
		columns+="${columns:+, }$ident"
		values+="${values:+, }$quoted"
		sets+="${sets:+, }$ident = $quoted"
	done
	if [ -n "${__save[$key]:-}" ]; then
		db_ident ident "$key" || return 1
		db_quote quoted "${__save[$key]}"
		db_query "UPDATE $table SET $sets WHERE $ident = $quoted" || return 1
	else
		db_query "INSERT INTO $table ($columns) VALUES ($values)" || return 1
		db_query "$_DB_LAST_ID_SQL" || return 1
		__save[$key]="${DB_ROWS[0]}"
	fi
}

# Public: `new` + `fill` + `save`: `create User user REQUEST_BODY_PARAMETERS`
function create()
{
	new "$1" "$2" || return 1
	fill "$2" "$3"
	save "$2"
}

# Public: DELETE the record's row. The array is left as is.
function delete()
{
	local -n __delete="$1"
	local model="${__delete[_model]}" table ident quoted
	db_ident table "${_MODEL_TABLE[$model]}" || return 1
	db_ident ident "${_MODEL_KEY[$model]}" || return 1
	db_quote quoted "${__delete[${_MODEL_KEY[$model]}]}"
	db_query "DELETE FROM $table WHERE $ident = $quoted"
}
