#!/bin/bash

# Database settings. Each one is only a default: a value already in the environment wins,
# so `DB_CONNECTION=pgsql bash server.sh` switches the driver, and so does a `.env` file at
# the root (`server.sh` exports its lines). Only the configured driver is loaded.

# sqlite | mysql | pgsql
: "${DB_CONNECTION:=sqlite}"
# sqlite: the file, relative to the root. mysql, pgsql: the database name
: "${DB_DATABASE:=database/database.sqlite}"
# mysql, pgsql. An empty host or port means the client's default (a local socket, 3306/5432)
: "${DB_HOST:=127.0.0.1}"
: "${DB_PORT:=}"
: "${DB_USERNAME:=}"
: "${DB_PASSWORD:=}"

# Redis is independent from `DB_CONNECTION`: see `redis()` in app/database/redis.sh
: "${REDIS_HOST:=127.0.0.1}"
: "${REDIS_PORT:=6379}"
: "${REDIS_PASSWORD:=}"
: "${REDIS_DB:=0}"
