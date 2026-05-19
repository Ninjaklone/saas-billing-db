# pgBouncer Setup — saas-billing-db

## Overview

pgBouncer sits between the application servers and PostgreSQL, multiplexing
many short-lived application connections onto a small number of long-lived
Postgres connections. Without it, each application thread holds a Postgres
connection open for its lifetime — at 10 app servers with 20 threads each,
that is 200 connections against a database with `max_connections = 100`.

This document covers: pool sizing rationale, configuration, userlist setup,
and an operational runbook for monitoring and responding to pool exhaustion.

---

## Pool sizing

### Inputs

| Parameter | Value | Reason |
|---|---|---|
| `max_connections` | 100 | Default on most RDS instances. 3 reserved for superuser. |
| Usable Postgres connections | 95 | 100 - 3 superuser - 2 monitoring/admin |
| App server instances | 10 | Assumed for a mid-size SaaS deployment |
| Pool mode | transaction | Correct mode for multi-tenant SaaS — see below |

### Calculation

```
pool_size (per database/user pair) = usable_connections / app_server_instances
= 95 / 10
= 9  (round down — never exceed max_connections)
```

Each app server gets a pool of 9 Postgres connections. Across 10 servers that
is 90 active connections maximum, leaving 5 for superuser and monitoring tools.

```
max_client_conn = app_server_threads * app_server_instances
= 20 * 10
= 200
```

pgBouncer will accept up to 200 client connections and multiplex them onto
the 90 Postgres connections. In transaction mode, a Postgres connection is
held only for the duration of a transaction — idle application threads consume
no Postgres connections at all.

### Why transaction mode

Transaction pooling releases the Postgres connection back to the pool the
moment a transaction commits or rolls back. A Postgres connection is only
held while a transaction is actually executing.

Session mode holds the connection for the lifetime of the client session —
effectively no pooling benefit for a multi-tenant application with many
idle connections.

Statement mode is incompatible with multi-statement transactions and cannot
be used here.

---

## Configuration

### `pgbouncer.ini`

```ini
[databases]
; Route saas_billing to the Postgres primary.
; Replace host with your RDS endpoint or primary hostname.
saas_billing = host=your-rds-endpoint.rds.amazonaws.com
               port=5432
               dbname=saas_billing

[pgbouncer]
; Network
listen_addr         = 0.0.0.0
listen_port         = 5432
unix_socket_dir     = /var/run/postgresql

; Auth
auth_type           = scram-sha-256
auth_file           = /etc/pgbouncer/userlist.txt

; Pooling
pool_mode           = transaction
max_client_conn     = 200
default_pool_size   = 9

; Reserve a small number of connections for superuser access
; even when the pool is fully saturated.
reserve_pool_size   = 3
reserve_pool_timeout = 5

; Drop client connections that have been waiting longer than this.
; Surfaces pool exhaustion to the application rather than queueing forever.
query_wait_timeout  = 30

; Kill server connections that have been idle longer than this.
; Prevents stale connections accumulating on the Postgres side.
server_idle_timeout = 600

; Logging
log_connections     = 1
log_disconnections  = 1
log_pooler_errors   = 1

; Admin
admin_users         = pgbouncer_admin
stats_users         = pgbouncer_stats

; TLS — required for RDS
client_tls_sslmode  = require
server_tls_sslmode  = require
```

### `userlist.txt`

Stores the credentials pgBouncer uses to authenticate clients and connect
to Postgres. Passwords are stored as scram-sha-256 hashes - never plaintext.

```ini 
; Format: "username" "scram-sha-256$<hash>"
; Generate the hash with: SELECT rolpassword FROM pg_authid WHERE rolname = 'app_user';
"app_user"          "scram-sha-256$<hash-from-pg_authid>"
"pgbouncer_admin"   "scram-sha-256$<hash-from-pg_authid>"
"pgbouncer_stats"   "scram-sha-256$<hash-from-pg_authid>"
```
To generate the hash for an existing Postgres user:

```sql
SELECT rolpassword FROM pg_authid WHERE rolname = 'app_user';
```

---

## Postgres side — required configuration

Two changes needed in `postgresql.conf` before pgBouncer connects:

```ini
; Allow pgBouncer to authenticate on behalf of application users.
; Without this, each user needs a direct Postgres login.
max_connections = 100
; Required for scram-sha-256 auth through pgBouncer
password_encryption = scram-sha-256
```

The application connects to pgBouncer on port 5432. pgBouncer connects to
Postgres — keep Postgres on a non-default port (5433) on the same host, or
on a separate host entirely, so there is no port conflict.

---

## RDS Proxy — managed equivalent

On AWS RDS, RDS Proxy provides the same connection pooling behaviour as
pgBouncer without the operational overhead of running and maintaining a
separate process.

| Concern | pgBouncer | RDS Proxy |
|---|---|---|
| Pool mode | Transaction (configured) | Transaction (default) |
| Max connections | Configured manually | Managed by AWS |
| Failover | Manual reconfiguration | Automatic — proxy endpoint stays stable |
| Auth | userlist.txt | IAM or Secrets Manager |
| Cost | Free (open source) | ~$0.015/hour per vCPU |
| Visibility | pgBouncer SHOW commands | CloudWatch metrics |

For this project, pgBouncer is the primary setup (self-managed, works with
any Postgres). RDS Proxy is documented as the production AWS alternative.
The application connection string is identical either way — only the host
changes.

To enable RDS Proxy on an existing RDS instance:
1. Open the RDS console → select the instance → **Proxies** → **Create proxy**
2. Set engine family to PostgreSQL
3. Set idle client timeout to match `server_idle_timeout` above (600s)
4. Attach a Secrets Manager secret containing the `app_user` credentials
5. Update the application `DATABASE_URL` to the proxy endpoint

---

## Operational runbook

### Monitoring commands

Connect to the pgBouncer admin console:

```bash
psql -h 127.0.0.1 -p 5432 -U pgbouncer_admin pgbouncer
```

**Pool status — run this first when investigating any connection issue:**

```sql
SHOW POOLS;
```

Key columns:

| Column | What it tells you |
|---|---|
| `cl_active` | Clients currently executing a query |
| `cl_waiting` | Clients waiting for a free Postgres connection |
| `sv_active` | Postgres connections currently in use |
| `sv_idle` | Postgres connections available in the pool |
| `sv_used` | Connections returned to pool but not yet reset |
| `maxwait` | Seconds the longest-waiting client has been queued |

**Overall statistics:**

```sql
SHOW STATS;
```

**Current client connections:**

```sql
SHOW CLIENTS;
```

**Current Postgres connections:**

```sql
SHOW SERVERS;
```

---

### Warning signs and responses

**`cl_waiting` > 0**
Clients are queuing for a Postgres connection. The pool is saturated.
Check `sv_idle` — if it is 0, all connections are in use.

Immediate response:
```sql
-- Identify long-running queries on the Postgres side
SELECT pid, now() - pg_stat_activity.query_start AS duration, query
FROM pg_stat_activity
WHERE state = 'active'
ORDER BY duration DESC;
```

If a long-running query is holding a connection, terminate it:
```sql
SELECT pg_terminate_backend(<pid>);
```

**`maxwait` > 10 seconds**
Clients have been waiting more than 10 seconds. `query_wait_timeout = 30`
will start dropping connections at 30 seconds. This will surface as
connection errors in the application.

Response: same as above. If the issue is sustained, temporarily increase
`default_pool_size` and reload pgBouncer — this buys time but is not a
fix:

```bash
kill -HUP $(pidof pgbouncer)   # reload config without restart
```

**`sv_used` accumulating**
Connections are being returned to the pool but not reset quickly. Usually
caused by long idle transactions on the application side.

Check for idle transactions on Postgres:
```sql
SELECT pid, state, now() - state_change AS idle_duration, query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
ORDER BY idle_duration DESC;
```

**Pool exhaustion during a deployment**
Rolling deployments temporarily double the number of app server instances.
With 10 servers at `default_pool_size = 9`, a rolling deploy to 20 servers
would request 180 connections — exceeding the 95 usable. Pre-scale by
temporarily reducing `default_pool_size` to 4 before the deploy, then
restore after.

---

## Connection string reference

```json
Application -> pgBouncer
DATABASE_URL=postgresql://app_user:<password>@pgbouncer-host:5432/saas_billing

pgBouncer admin console
ADMIN_URL=postgresql://pgbouncer_admin:<password>@127.0.0.1:5432/pgbouncer

Direct to Postgres (bypass pgBouncer — migrations and superuser tasks only)
DIRECT_URL=postgresql://postgres:<password>@postgres-host:5433/saas_billing
```

Never run migrations through pgBouncer. Migrations use DDL statements that
are incompatible with transaction pooling mode -run them directly against
Postgres using `DIRECT_URL`. I mean the reasons are pretty obvious, one 
being that pgBouncer pool connections will never persist as long as a 
schema change operation usually persists breaking the connection and leading
to divergent schema changes during migration.