#!/bin/bash

# Apply the database/migrations/*.sql files not yet applied, in name order, on the
# configured connection (`.env` or the environment, see config/database.sh). Each file is
# sent as one batch; `{{ id }}` in it stands for the driver's auto-increment primary key.
# Applied names are kept in a `migrations` table.
#
#    bash scripts/migrate.sh
#    DB_CONNECTION=pgsql bash scripts/migrate.sh

set -efu

cd "$(dirname "$0")/.."
if [ -f .env ]; then
	set -a
	source .env
	set +a
fi
source app/helpers.sh

if [ "$DB_CONNECTION" = sqlite ]; then
	mkdir -p "$(dirname "$DB_DATABASE")"
fi

db_query 'CREATE TABLE IF NOT EXISTS migrations (name VARCHAR(255) PRIMARY KEY)' || exit 1
db_query 'SELECT name FROM migrations' || exit 1
applied=" ${DB_ROWS[*]+"${DB_ROWS[*]}"} "

set +f
count=0
for file in database/migrations/*.sql; do
	name="${file##*/}"
	if [[ "$applied" == *" $name "* ]]; then
		continue
	fi
	IFS= read -r -d '' sql < "$file" || true
	sql="${sql//'{{ id }}'/$_DB_ID_COLUMN}"
	if ! db_query "$sql"; then
		printf 'FAILED %s\n' "$name" >&2
		exit 1
	fi
	db_quote quoted "$name"
	db_query "INSERT INTO migrations (name) VALUES ($quoted)" || exit 1
	printf 'migrated %s\n' "$name"
	count=$(( count + 1 ))
done
printf '%s: %d migration(s) applied\n' "$DB_CONNECTION" "$count"
