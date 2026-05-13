# read-after-write violation under `binlog_order_commits=ON`

A minimal shell reproducer showing that MySQL, in its default configuration,
violates the read-after-write contract implied by `binlog_order_commits=ON`:
a row event delivered to a binlog replication client can refer to a row that
is **not yet visible** to a fresh `SELECT` on a separate connection.

The window is short — almost always under 100 ms — but it is wide enough to
break tools that treat "saw it in the binlog" as a guarantee that the row
can now be read back from the source table.

## The contract

From the [MySQL reference manual for
`binlog_order_commits`](https://dev.mysql.com/doc/refman/8.4/en/replication-options-binary-log.html#sysvar_binlog_order_commits)
(default: `ON`):

> When this variable is enabled on a replication source server (which is the
> default setting), transactions are externalized in the same order as they
> are written to the binary log.

And from the same page, immediately below:

> When disabled, transactions may be committed in parallel. In some cases,
> this might provide a performance increment.

The promise of `ON` is that the binary log is the linearizing log of commits.
By the time a binlog row event becomes deliverable to a replication client,
the corresponding InnoDB commit has finished and is observable to **every**
subsequent read view on every other connection. That is the property that
makes "tail the binlog" a sound way to know what is now durably committed.

## The violation

This reproducer drives a small InnoDB table from N concurrent writer
connections, each looping the minimum transaction shape that surfaces the
race:

```sql
BEGIN;
INSERT INTO t (payload) VALUES ('x');
UPDATE t SET payload = 'x2' WHERE id = LAST_INSERT_ID();
COMMIT;
```

A separate process tails the binlog with `mysqlbinlog
--read-from-remote-server --stop-never --verbose` and, for every
`WriteRowsEvent` that arrives, immediately issues
`SELECT id FROM t WHERE id = ?` on a fresh autocommit connection.

That `SELECT` should never miss. With `binlog_order_commits=ON`, the
row event in the streamer's hand implies the commit is already visible
everywhere. We observe that the `SELECT` does sometimes miss, and the row
becomes visible a short time later (typically under 100 ms — the reproducer
calls this case `DELAYED`). A small number of `PERMANENT` misses have also
been seen (still invisible after 100 ms), making the contract violation
strict rather than just a soft visibility lag.

The single-statement variants — autocommit `INSERT`, or `BEGIN; INSERT;
COMMIT;` — do not surface the race in the same time budget. The
INSERT+UPDATE-in-the-same-transaction shape is the minimum trigger.

The race has been observed on MySQL 8.0, 8.4, and 9.x, on Linux. It has not
been reproduced on macOS-native MySQL in short runs, but the same Docker
images that reproduce it on Linux CI runners reproduce it on Linux
elsewhere, so the most parsimonious read is that the window is simply
narrower on Darwin's scheduler.

## Why this breaks tools like spirit

[spirit](https://github.com/block/spirit) is an online schema change tool.
At a high level, during a migration it:

1. Copies the source table `t` row-by-row into a shadow table `_t_new`.
2. Subscribes to the binlog. For every row event on `t`, it records the
   primary key in a delta map.
3. Periodically flushes the delta map: `REPLACE INTO _t_new (...) SELECT
   ... FROM t FORCE INDEX (PRIMARY) WHERE id IN (...)`.

Step 3 is the load-bearing one. Spirit's correctness argument is exactly
the `binlog_order_commits` contract: by the time the binlog subscription
hands us a key, the row is committed, so the `SELECT FROM t WHERE id IN
(...)` is guaranteed to return it.

Under the bug, that assumption is wrong. The flush statement returns
`num_keys=3 affected_rows=2` — three primary keys in the delta map, but the
`SELECT FROM t` only sees two of them. The third row is genuinely committed
(its INSERT was logged to the binlog after a successful `COMMIT`); it is
just not yet visible on the connection issuing the flush. The flush
silently produces a partial result. The delta-map entry for the missing key
gets removed anyway (the standard flow assumes a successful flush
means the row landed in `_t_new`), so the row is permanently absent from
the new table.

The failure mode is post-cutover checksum or row-count divergence between
`t_old` and `t_new`. See spirit issue
[#746](https://github.com/block/spirit/issues/746) for the full
investigation, the diagnostic logging that confirmed the
`num_keys != affected_rows` smoking gun, and the chosen workaround
(switching from the delta-map subscription to a buffered subscription that
applies row images directly from the binlog event payload rather than
re-reading from the source table).

The same shape will affect any tool whose correctness depends on "if I
see the row event, I can read the row back" — change-data-capture
pipelines that enrich an event by querying the source table, audit tools
that diff a binlog-derived set against the source, etc.

## What about `binlog_order_commits=OFF`?

The setting exists and can be turned off. We are **not** suggesting that as
a fix. The relevant case is the **default** (`ON`), which everyone running
unmodified MySQL is running. Turning the setting off explicitly opts into
unordered commits and out of any read-after-write guarantee; that is a
documented trade-off. The bug here is that the documented `ON` semantics
are not honored.

Workloads that have set `binlog_order_commits=OFF` have already accepted
that the binlog is not a linearizer of commits and have presumably built
their tooling around that. The class of tool described above
(spirit, CDC enrichers, audit jobs) implicitly assumes the default — that
is the configuration where the contract is supposed to hold and where the
violation matters.

## Running the reproducer

Requires `bash`, `mysql` client, `mysqlbinlog`, `awk`. Defaults assume a
vanilla `mysql:*` Docker image with `MYSQL_ROOT_PASSWORD=msandbox` on
`127.0.0.1:3306`:

```
docker run -d --name mysql -e MYSQL_ROOT_PASSWORD=msandbox -p 3306:3306 mysql:8.0
./repro.sh -t 240 -w 8
```

Flags: `-h host` `-P port` `-u user` `-p pass` `-w writers` `-t max_seconds`
`-r recheck_ms`. Exit codes: `1` first miss observed (bug reproduced), `0`
no miss within `-t`, `2` infrastructure failure.

The companion GitHub Actions workflow at
`.github/workflows/read-after-write-violation.yml` runs the matrix
`{ubuntu-22.04, ubuntu-24.04, ubuntu-latest} × {mysql:8.0, mysql:8.4,
mysql:9.7}` weekly so a future patch release that fixes the violation
shows up as the matrix cells flipping from green (bug reproduced) to red
(bug not reproduced).
