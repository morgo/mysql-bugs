#!/usr/bin/env bash
#
# Standalone shell reproducer for an apparent MySQL contract violation:
# with binlog_order_commits=ON (the default), a row event observable to a
# binlog replication client is sometimes NOT yet visible to a fresh
# autocommit SELECT on a separate connection.
#
# MySQL contract (per the docs for binlog_order_commits, default ON):
#
#   "transactions commit to InnoDB in the same order as their writes to
#    the binary log"
#
# In particular, by the time a binlog row event is deliverable to a
# replication client, the corresponding InnoDB commit has finished and
# the row is visible to every subsequent read view on every other
# connection. A fresh autocommit SELECT MUST see the row.
#
# The script:
#
#   1. Creates a temporary database with a small InnoDB table.
#   2. Spawns N writer subshells looping BEGIN; INSERT; UPDATE; COMMIT
#      against that table (this is the minimum producer shape that
#      surfaces the race -- see the bisect note below).
#   3. Streams the live binlog via "mysqlbinlog --read-from-remote-server
#      --verbose --stop-never" and, for every WriteRowsEvent on the test
#      table, immediately runs "SELECT id FROM <table> WHERE id = ?" on a
#      fresh connection.
#   4. On the first miss: sleeps the recheck delay, re-runs the SELECT
#      and classifies the miss as DELAYED (visible after the wait) or
#      PERMANENT (still invisible). Both are violations; "delayed" is
#      the soft form, "permanent" the hard form.
#   5. Exits 1 on the first miss, 0 if no miss observed within
#      --max-duration, 2 on infrastructure problems (no events, no
#      commits, missing tools, ...).
#
# Producer-shape bisect (observed on MySQL 8.0.x / 8.4 / 9.x on Linux):
#
#   autocommit INSERT … VALUES (…)   no reproduction observed
#   BEGIN; INSERT; COMMIT;           no reproduction observed
#   BEGIN; INSERT; UPDATE; COMMIT;   reproduces (probabilistic)
#
# Single-statement transactions don't trigger it in the same time budget.
# The minimum producer shape is therefore a multi-statement transaction
# that INSERTs and then UPDATEs the same row before COMMIT.
#
# Usage:
#   ./repro.sh [-h HOST] [-P PORT] [-u USER] [-p PASS]
#              [-w WRITERS] [-t MAX_SECONDS] [-r RECHECK_MS]
#
# Defaults assume a vanilla mysql:* docker image with
# MYSQL_ROOT_PASSWORD=msandbox on 127.0.0.1:3306.
#
# Dependencies: bash 4+, mysql client, mysqlbinlog, awk. No GNU
# coreutils required (no timeout(1)) so the script also runs on macOS.

set -u
set -o pipefail

HOST=127.0.0.1
PORT=3306
USERNAME=root
PASSWORD=msandbox
WRITERS=8
MAX_SECS=300
RECHECK_MS=100

while getopts ":h:P:u:p:w:t:r:" opt; do
  case $opt in
    h) HOST=$OPTARG ;;
    P) PORT=$OPTARG ;;
    u) USERNAME=$OPTARG ;;
    p) PASSWORD=$OPTARG ;;
    w) WRITERS=$OPTARG ;;
    t) MAX_SECS=$OPTARG ;;
    r) RECHECK_MS=$OPTARG ;;
    *)
      echo "usage: $0 [-h host] [-P port] [-u user] [-p pass] [-w writers] [-t max_secs] [-r recheck_ms]" >&2
      exit 2
      ;;
  esac
done

command -v mysql >/dev/null || { echo "mysql client not found in PATH" >&2; exit 2; }
command -v mysqlbinlog >/dev/null || { echo "mysqlbinlog not found in PATH" >&2; exit 2; }

# Use MYSQL_PWD so we don't have to pass --password=... on the command
# line (which prints a warning and shows up in ps output).
export MYSQL_PWD="$PASSWORD"

MYSQL_ARGS=(
  -h "$HOST" -P "$PORT" -u "$USERNAME"
  --protocol=tcp --batch --silent --skip-column-names
  --connect-timeout=5
)

run_mysql() { mysql "${MYSQL_ARGS[@]}" "$@"; }

DB="binlog_vis_repro_$$_$(date +%s)"
TABLE="stress_repro"
WRITER_PIDS=()
MISS_KIND=""
MISS_ID=""
EVENTS=0

cleanup() {
  # Best-effort: kill writers + binlog tail, drop the throwaway db.
  # `jobs -p` catches the process-substitution-backed binlog pipeline
  # that doesn't have an explicit pid we captured.
  local bg
  bg=$(jobs -p 2>/dev/null)
  if [ -n "$bg" ]; then
    # shellcheck disable=SC2086 # we want word splitting here
    kill $bg 2>/dev/null || true
  fi
  if [ "${#WRITER_PIDS[@]}" -gt 0 ]; then
    kill "${WRITER_PIDS[@]}" 2>/dev/null || true
  fi
  wait 2>/dev/null || true
  run_mysql -e "DROP DATABASE IF EXISTS \`$DB\`" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Server settings:"
# A pretty-printed key=value line: --silent --skip-column-names already
# strips column headers, so we just emit one value per @@var per line.
for v in version binlog_format binlog_row_image binlog_order_commits sync_binlog innodb_flush_log_at_trx_commit; do
  val=$(run_mysql -e "SELECT @@global.$v" 2>/dev/null || echo "?")
  printf '  %s=%s\n' "$v" "$val"
done

run_mysql -e "CREATE DATABASE \`$DB\`"
run_mysql "$DB" <<SQL
CREATE TABLE \`$TABLE\` (
  id      BIGINT NOT NULL PRIMARY KEY AUTO_INCREMENT,
  payload VARCHAR(255) NOT NULL
) ENGINE=InnoDB;
SQL

# Identify the current binlog file so mysqlbinlog --stop-never has
# something to start from. MySQL 8.4 renamed SHOW MASTER STATUS to
# SHOW BINARY LOG STATUS; try the new name first, fall back.
BINLOG_FILE=$(run_mysql -e "SHOW BINARY LOG STATUS" 2>/dev/null | awk 'NR==1{print $1}')
if [ -z "${BINLOG_FILE:-}" ]; then
  BINLOG_FILE=$(run_mysql -e "SHOW MASTER STATUS" 2>/dev/null | awk 'NR==1{print $1}')
fi
[ -n "${BINLOG_FILE:-}" ] || { echo "could not determine current binlog file" >&2; exit 2; }
echo "starting binlog tail from $BINLOG_FILE"
echo "writers=$WRITERS max_duration=${MAX_SECS}s recheck_delay=${RECHECK_MS}ms"

# Spawn writer subshells. Each runs the minimum producer shape that
# triggers the race: BEGIN; INSERT; UPDATE same row; COMMIT.
for ((i = 1; i <= WRITERS; i++)); do
  (
    while :; do
      run_mysql "$DB" >/dev/null 2>&1 <<SQL || true
START TRANSACTION;
INSERT INTO \`$TABLE\` (payload) VALUES ('x');
UPDATE \`$TABLE\` SET payload = 'x2' WHERE id = LAST_INSERT_ID();
COMMIT;
SQL
    done
  ) &
  WRITER_PIDS+=($!)
done

# Stream the binlog and emit each new INSERTed id as a single line.
#
# mysqlbinlog --verbose prints, for each row event, a pseudo-SQL block:
#
#   ### INSERT INTO `<db>`.`<table>`
#   ### SET
#   ###   @1=<id> /* INT meta=... */
#   ###   @2='x' /* VARCHAR(...) meta=... */
#
# We exact-match the "### INSERT INTO" header line for our table, then
# pick up the @1 (PK) line that follows.
#
# The whole pipeline is attached to FD 3 via process substitution so
# the verifier loop runs in the *current* shell (so it can set
# MISS_KIND / MISS_ID and exit cleanly). We use "read -t REMAINING"
# instead of timeout(1) so the script works on macOS without GNU
# coreutils.

exec 3< <(
  mysqlbinlog \
    --read-from-remote-server \
    --host="$HOST" \
    --port="$PORT" \
    --user="$USERNAME" \
    --verbose \
    --stop-never \
    "$BINLOG_FILE" 2>/dev/null \
  | awk -v db="$DB" -v tbl="$TABLE" '
      BEGIN { in_insert = 0; header = "### INSERT INTO `" db "`.`" tbl "`" }
      {
        if (in_insert) {
          if ($0 ~ /^###[[:space:]]+@1=/) {
            v = $0
            sub(/^###[[:space:]]+@1=/, "", v)
            # Strip the trailing " /* INT meta=... */" comment.
            n = index(v, " /*")
            if (n > 0) v = substr(v, 1, n - 1)
            print v
            fflush()
            in_insert = 0
            next
          }
          if ($0 !~ /^###/) in_insert = 0
        }
        if ($0 == header) in_insert = 1
      }'
)

END_TIME=$(( $(date +%s) + MAX_SECS ))

while :; do
  remaining=$(( END_TIME - $(date +%s) ))
  if [ "$remaining" -le 0 ]; then
    break
  fi
  if ! IFS= read -r -t "$remaining" -u 3 id; then
    # Timed out waiting for next id, or stream EOF.
    break
  fi
  [ -n "$id" ] || continue
  EVENTS=$((EVENTS + 1))

  # Fast path: row visible right away.
  if [ -n "$(run_mysql "$DB" -e "SELECT id FROM \`$TABLE\` WHERE id = $id" 2>/dev/null)" ]; then
    continue
  fi

  # First miss. Classify with a recheck after the configured delay.
  echo
  echo "first miss observed: id=$id (row event delivered, fresh SELECT does not see the row) -- re-checking after ${RECHECK_MS}ms"
  sleep_secs=$(awk -v ms="$RECHECK_MS" 'BEGIN { printf "%.3f", ms/1000.0 }')
  sleep "$sleep_secs"
  if [ -n "$(run_mysql "$DB" -e "SELECT id FROM \`$TABLE\` WHERE id = $id" 2>/dev/null)" ]; then
    MISS_KIND="delayed"
    echo "MISSING (delayed)   id=$id -- row became visible after ${RECHECK_MS}ms"
  else
    MISS_KIND="permanent"
    echo "MISSING (permanent) id=$id -- row still not visible to a fresh SELECT after ${RECHECK_MS}ms"
  fi
  MISS_ID=$id
  break
done

exec 3<&-

echo
echo "SUMMARY: writers=$WRITERS events_observed=$EVENTS"

case "$MISS_KIND" in
  permanent)
    echo "FAIL: binlog_order_commits=ON contract was violated."
    echo "Row event was observed in the binlog stream but the corresponding row"
    echo "was NOT visible to a fresh SELECT even after ${RECHECK_MS}ms (id=$MISS_ID)."
    exit 1
    ;;
  delayed)
    echo "FAIL: binlog_order_commits=ON contract was violated."
    echo "Row event was observed in the binlog stream but the corresponding row"
    echo "only became visible to a fresh SELECT after ${RECHECK_MS}ms (id=$MISS_ID)."
    echo "The visibility lag is transient but it is still a contract violation."
    exit 1
    ;;
esac

if [ "$EVENTS" -eq 0 ]; then
  echo "INCONCLUSIVE: no INSERT row events observed -- check connectivity, log_bin, binlog_format=ROW, and that mysqlbinlog can read the binlog as user '$USERNAME'."
  exit 2
fi

echo "PASS: no visibility violations observed within ${MAX_SECS}s."
exit 0
