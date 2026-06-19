# Replication Setup — saas-billing-db

## Overview

This document covers streaming replication between a primary PostgreSQL
instance and one synchronous standby. The standby receives WAL records from
the primary in real time and must confirm receipt before the primary
acknowledges a commit.

**Synchronous replication guarantee:** No committed transaction is lost on
failover. The primary will never acknowledge a commit that the standby has
not received. The trade-off is that every write waits for a network
round-trip to the standby — acceptable for a billing system where financial
integrity outweighs write latency.

---

## Architecture

```
Application
|
▼
pgBouncer (:5432)
|
▼
Primary PostgreSQL (:5433) --- WAL stream ---> Standby PostgreSQL (:5433)
(synchronous)
```

Note: The port numbers are for reference as used on my config.

The standby is read-only. It serves two purposes:
- **High availability** — promoted to primary if the primary fails
- **Read scaling** — reporting and monitoring queries can be routed here
  to reduce load on the primary

---

## Primary configuration

### `postgresql.conf`

```ini
# Replication role
wal_level                   = replica        -- minimum for streaming replication
max_wal_senders             = 5              -- max concurrent standby connections
wal_keep_size               = 256MB          -- retain WAL segments for standbys
                                             -- increase if standby falls behind

# Synchronous replication
# Replace standby_hostname with the application_name set in recovery.conf
synchronous_standby_names   = 'FIRST 1 (saas_billing_standby)'
synchronous_commit          = on             -- wait for standby WAL receipt

# Replication slots — optional but recommended
# Prevents WAL deletion before standby has consumed it
# Risk: if standby goes offline, WAL accumulates indefinitely — monitor disk
max_replication_slots       = 5

# Connection
listen_addresses            = '*'
port                        = 5433
```


### `pg_hba.conf`

Add this entry to allow the replication user to connect from the standby:
```ini 
TYPE  DATABASE        USER            ADDRESS                 METHOD
host    replication     replicator      <standby-ip>/32         scram-sha-256
```

Replace `<standby-ip>` with the standby server's IP address. Never use
`0.0.0.0/0` — the replication user must be locked to the standby IP
and if for any reason you use `0.0.0.0/0` make sure to lock it back on 
to the standby IP.

### Create the replication user

```sql
CREATE USER replicator
    WITH REPLICATION
    ENCRYPTED PASSWORD '<strong-password>'
    LOGIN;
```

This user has no other privileges — replication only.

### Reload primary configuration

```bash
# Reload without restart — picks up pg_hba.conf and most postgresql.conf changes
pg_ctl reload -D /var/lib/postgresql/data

# Full restart required if wal_level or max_wal_senders was changed
pg_ctl restart -D /var/lib/postgresql/data
```

---

## Standby provisioning

### Step 1 — take a base backup from the primary

Run this on the standby server. It copies the entire primary data directory
to the standby and establishes the starting point for WAL streaming.

```bash
pg_basebackup \
    --host=<primary-ip> \
    --port=5433 \
    --username=replicator \
    --pgdata=/var/lib/postgresql/data \
    --wal-method=stream \
    --checkpoint=fast \
    --progress \
    --verbose
```

`--wal-method=stream` streams WAL during the backup itself — the standby
will be consistent from the moment the backup completes without needing
to replay a large WAL backlog.

### Step 2 — configure the standby

Create `postgresql.conf` on the standby with these additions:

```ini
port                        = 5433
hot_standby                 = on     -- allow read queries on the standby
hot_standby_feedback        = on     -- inform primary of standby query conflicts
```

Create `postgresql.auto.conf` (or `recovery.conf` on Postgres < 12) on the
standby data directory:

```ini
primary_conninfo = 'host=<primary-ip> port=5433 user=replicator
                   password=<password> application_name=saas_billing_standby
                   sslmode=require'

primary_slot_name           = 'saas_billing_standby_slot'  -- if using slots
restore_command             = ''                            -- not needed for streaming
```

`application_name` must match the name in `synchronous_standby_names` on
the primary exactly.

### Step 3 — create a replication slot on the primary (if using slots)

```sql
SELECT pg_create_physical_replication_slot('saas_billing_standby_slot');
```

### Step 4 — create the standby signal file

```bash
touch /var/lib/postgresql/data/standby.signal
```

Postgres 12+ uses the presence of this file to start in standby mode.

### Step 5 — start the standby

```bash
pg_ctl start -D /var/lib/postgresql/data
```

---

## Verifying replication is working

Run these on the primary after the standby starts.

### Confirm the standby is connected

```sql
SELECT
    application_name,
    client_addr,
    state,
    sync_state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn
FROM pg_stat_replication;
```

Expected output:

| Column | Expected value |
|---|---|
| `application_name` | `saas_billing_standby` |
| `state` | `streaming` |
| `sync_state` | `sync` |
| `sent_lsn` | matches or leads `replay_lsn` |

If `sync_state` shows `async` instead of `sync`, the `application_name`
in `primary_conninfo` does not match `synchronous_standby_names` — check
both values.

### Check replication lag

```sql
SELECT
    application_name,
    write_lag,
    flush_lag,
    replay_lag
FROM pg_stat_replication;
```

In normal operation all three lag values should be milliseconds or NULL
(NULL means no lag — the standby is current). Sustained lag over 1 second
warrants investigation.

### Check WAL slot retention (if using slots)

```sql
SELECT
    slot_name,
    active,
    pg_size_pretty(
        pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
    ) AS retained_wal
FROM pg_replication_slots;
```

If `retained_wal` is growing and `active` is FALSE, the standby is offline
and WAL is accumulating. If disk space is at risk, drop the slot temporarily:

```sql
SELECT pg_drop_replication_slot('saas_billing_standby_slot');
```

Recreate it when the standby comes back online and re-provision from a fresh
base backup.

---

## Monitoring queries — run regularly

### Replication lag in bytes

```sql
SELECT
    application_name,
    pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
FROM pg_stat_replication;
```

### Confirm standby is in recovery mode (run on standby)

```sql
SELECT pg_is_in_recovery();
-- Must return TRUE while the instance is a standby
```

### Confirm standby LSN position (run on standby)

```sql
SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();
-- Both should match or be within milliseconds of each other
```

---

## Failover runbook

Follow this sequence exactly. Deviating from the order risks a split-brain
scenario where both instances accept writes simultaneously.

### Trigger conditions

Initiate failover when any of the following are true:
- Primary is unreachable for more than 30 seconds
- `pg_stat_replication` shows no connected standbys for more than 60 seconds
- Primary disk is full and cannot be recovered quickly
- Primary hardware failure confirmed

Do not initiate failover for transient network issues — wait 30 seconds and
recheck before proceeding.

---

### Step 1 — confirm the primary is truly down

```bash
# From the standby server
pg_isready -h <primary-ip> -p 5433
# Expected: no response or "no attempt"

psql -h <primary-ip> -p 5433 -U postgres -c "SELECT 1;"
# Expected: connection refused or timeout
```

Do not proceed to Step 2 until you are certain the primary is not accepting
connections. A primary that is slow but alive must be shut down before the
standby is promoted.

---

### Step 2 — shut down the primary if it is reachable

If the primary is reachable but degraded, shut it down cleanly before
promoting the standby. This prevents a rogue primary scenario.

```bash
pg_ctl stop -D /var/lib/postgresql/data -m fast
```

If the primary is completely unreachable, proceed to Step 3. Document that
a clean shutdown was not possible — the old primary must not be brought
back online without being re-provisioned as a standby first.

---

### Step 3 — promote the standby

```bash
# Option A — pg_promote() via SQL (Postgres 12+, preferred)
psql -h <standby-ip> -p 5433 -U postgres -c "SELECT pg_promote();"

# Option B — pg_ctl promote
pg_ctl promote -D /var/lib/postgresql/data
```

`pg_promote()` triggers the standby to finish replaying any remaining WAL,
remove the `standby.signal` file, and begin accepting write connections.
This takes seconds.

---

### Step 4 — verify promotion succeeded

```sql
-- Run on the promoted standby (now primary)
SELECT pg_is_in_recovery();
-- Must return FALSE

SELECT now();
-- Must return a current timestamp — confirms writes are accepted
```

Update pgBouncer to point at the new primary:

```ini
; pgbouncer.ini — update the host
[databases]
saas_billing = host=<new-primary-ip> port=5433 dbname=saas_billing
```

Reload pgBouncer:

```bash
kill -HUP $(pidof pgbouncer)
```

---

### Step 5 — verify application connectivity

```bash
psql -h <pgbouncer-ip> -p 5432 -U app_user saas_billing -c "SELECT COUNT(*) FROM tenants;"
```

Application traffic should resume within seconds of the pgBouncer reload.

---

### Step 6 — prevent the old primary from rejoining as a primary

If the old primary comes back online after an unclean shutdown, it must not
be allowed to accept application connections. Before bringing it back:

1. Ensure pgBouncer no longer points to it — confirmed in Step 4
2. Do not start Postgres on the old primary until it has been re-provisioned
   as a standby — see Step 7

If the old primary starts accidentally and accepts writes, you have a
split-brain. Stop it immediately:

```bash
pg_ctl stop -D /var/lib/postgresql/data -m immediate
```

Then re-provision as a standby from scratch.

---

### Step 7 — re-provision the old primary as the new standby

Once the old primary is safely offline, rebuild it as a standby of the
new primary using a fresh base backup:

```bash
# Clear the old data directory
rm -rf /var/lib/postgresql/data/*

# Take a fresh base backup from the new primary
pg_basebackup \
    --host=<new-primary-ip> \
    --port=5433 \
    --username=replicator \
    --pgdata=/var/lib/postgresql/data \
    --wal-method=stream \
    --checkpoint=fast \
    --progress

# Recreate standby configuration
cat > /var/lib/postgresql/data/postgresql.auto.conf << EOF
primary_conninfo = 'host=<new-primary-ip> port=5433 user=replicator
                   password=<password> application_name=saas_billing_standby
                   sslmode=require'
EOF

touch /var/lib/postgresql/data/standby.signal

pg_ctl start -D /var/lib/postgresql/data
```

Verify replication is re-established on the new primary:

```sql
SELECT application_name, state, sync_state
FROM pg_stat_replication;
-- Expected: saas_billing_standby | streaming | sync
```

---

## RDS Multi-AZ — managed equivalent

On AWS RDS, Multi-AZ provides synchronous replication to a standby instance
in a different availability zone. The behaviour maps directly to what is
documented above.

| Concern | Self-managed | RDS Multi-AZ |
|---|---|---|
| Replication mode | Synchronous (configured) | Synchronous (default) |
| Failover trigger | Manual (this runbook) | Automatic — 60–120 seconds |
| Standby visibility | Queryable via `hot_standby` | Not directly queryable |
| Read replica | Separate async replica needed | Separate read replica needed |
| Failover DNS | Manual pgBouncer update | CNAME flips automatically |
| Re-provisioning | Manual base backup | Automatic |

The key operational difference: RDS Multi-AZ failover is automatic and the
endpoint DNS flips to the standby within 60–120 seconds. pgBouncer does not
need to be updated because the endpoint hostname stays the same. The
trade-off is that the standby is not queryable — a separate read replica is
needed for read scaling.