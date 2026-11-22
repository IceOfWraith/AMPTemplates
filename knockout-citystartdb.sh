#!/bin/bash
# Starts this instance's own PostgreSQL and Redis servers for Knockout City.
# Usage: startdb.sh <data directory> <PostgreSQL port> <Redis port>
# Both servers listen on 127.0.0.1 only and keep their data in the given directory.

DATA_DIR="$1"
PG_PORT="$2"
REDIS_PORT="$3"

PG_BIN=$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -n 1)
if [ -z "$PG_BIN" ] || ! command -v redis-server >/dev/null 2>&1; then
  echo "PostgreSQL or Redis is not installed. This template must run in a container."
  exit 1
fi

PG_DATA="$DATA_DIR/postgresql"
REDIS_DATA="$DATA_DIR/redis"
mkdir -p "$PG_DATA" "$REDIS_DATA"
chmod 700 "$PG_DATA"

if [ ! -f "$PG_DATA/PG_VERSION" ]; then
  echo "Creating PostgreSQL database cluster"
  if ! "$PG_BIN/initdb" -D "$PG_DATA" -U koc -A trust -E UTF8 >"$DATA_DIR/initdb.log" 2>&1; then
    echo "PostgreSQL initdb failed, see $DATA_DIR/initdb.log"
    exit 1
  fi
fi

if ! "$PG_BIN/pg_isready" -q -h 127.0.0.1 -p "$PG_PORT"; then
  "$PG_BIN/pg_ctl" -D "$PG_DATA" stop -m fast >/dev/null 2>&1
  echo "Starting PostgreSQL on 127.0.0.1:$PG_PORT"
  if ! "$PG_BIN/pg_ctl" -D "$PG_DATA" -w -t 60 -l "$DATA_DIR/postgresql.log" -o "-p $PG_PORT -h 127.0.0.1 -k $PG_DATA" start >/dev/null; then
    echo "PostgreSQL failed to start, see $DATA_DIR/postgresql.log"
    exit 1
  fi
fi

if ! "$PG_BIN/psql" -h 127.0.0.1 -p "$PG_PORT" -U koc -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='koc'" | grep -q 1; then
  "$PG_BIN/createdb" -h 127.0.0.1 -p "$PG_PORT" -U koc koc || exit 1
fi

if ! redis-cli -h 127.0.0.1 -p "$REDIS_PORT" ping 2>/dev/null | grep -q PONG; then
  echo "Starting Redis on 127.0.0.1:$REDIS_PORT"
  redis-server --bind 127.0.0.1 --port "$REDIS_PORT" --dir "$REDIS_DATA" --daemonize yes --logfile "$DATA_DIR/redis.log" --pidfile "$REDIS_DATA/redis.pid" || exit 1
  for i in $(seq 1 30); do
    redis-cli -h 127.0.0.1 -p "$REDIS_PORT" ping 2>/dev/null | grep -q PONG && break
    sleep 1
  done
  if ! redis-cli -h 127.0.0.1 -p "$REDIS_PORT" ping 2>/dev/null | grep -q PONG; then
    echo "Redis failed to start, see $DATA_DIR/redis.log"
    exit 1
  fi
fi

echo "PostgreSQL and Redis are ready"
exit 0
