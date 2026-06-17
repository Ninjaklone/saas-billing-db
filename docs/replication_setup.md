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
