# PXC Cluster Lab

A 3-node **Percona XtraDB Cluster (PXC) 8.4** (Galera) + **ProxySQL** test lab
built entirely from Docker containers running on **Ubuntu 24.04**, driven by
a single `Makefile`. It's meant for learning: bootstrapping a Galera
cluster, watching State Snapshot Transfer (SST) happen, killing nodes and
watching ProxySQL fail over, and practicing disaster recovery — all on your
laptop, all disposable.

```
                        ┌─────────────────────┐
                        │        you          │
                        │  (mysql client / app)│
                        └──────────┬───────────┘
                                   │ :6033 (MySQL protocol)
                                   │ :6032 (admin)
                         ┌─────────▼──────────┐
                         │      ProxySQL       │   Debian-based
                         │  galera-aware       │   (proxysql/proxysql)
                         │  read/write split   │
                         └──┬───────┬───────┬──┘
                    hg10/11 │       │       │ hg20 (readers)
                   (writer) │       │       │
              ┌─────────────▼┐  ┌───▼──────┐  ┌▼─────────────┐
              │  pxc-node1   │  │pxc-node2 │  │  pxc-node3   │
              │  Ubuntu 24.04│◄─┤Ubuntu24.04├─►│ Ubuntu 24.04 │
              │  PXC 8.4     │  │PXC 8.4   │  │ PXC 8.4      │
              └──────────────┘  └──────────┘  └──────────────┘
                     Galera replication (synchronous, all-to-all)
                     :4567 group comm  :4444 SST  :4568 IST
```

## Why a custom image?

Percona's official `percona/percona-xtradb-cluster` Docker images are built
on **Red Hat UBI9-minimal**, not Ubuntu/Debian. Since this lab specifically
wants an Ubuntu/Debian stack, [`docker/pxc/Dockerfile`](docker/pxc/Dockerfile)
builds PXC from scratch on `ubuntu:24.04` using Percona's official apt
repository (`percona-release setup pxc-84-lts`), and
[`docker/pxc/entrypoint.sh`](docker/pxc/entrypoint.sh) reimplements the
bootstrap/join/SST orchestration that Percona's own image normally handles
for you. ProxySQL uses the official `proxysql/proxysql` image pinned to a
`-debian` tag for the same reason.

This means the entrypoint script is worth reading — it's the actual
Galera operations knowledge (bootstrap vs. join, `wsrep_cluster_address`,
`grastate.dat`, `safe_to_bootstrap`) spelled out in ~150 lines of bash
instead of hidden inside a vendor image.

## What's in this repo

```
.
├── Makefile                      # every command you need, see `make help`
├── docker-compose.yml            # 3 PXC nodes + ProxySQL + one-shot init job
├── .env.example                  # copy to .env and change the passwords
├── docker/pxc/
│   ├── Dockerfile                # Ubuntu 24.04 + Percona apt repo (PXC 8.4)
│   └── entrypoint.sh             # bootstrap / join / SST / recovery logic
├── proxysql/
│   └── proxysql.cnf.template     # rendered to generated/proxysql.cnf
├── sql/
│   ├── proxysql_init.sql.template # galera hostgroups, users, query rules
│   └── 02-sample-schema.sql       # demo table, applied on first bootstrap
├── generated/                    # rendered configs (gitignored)
└── backups/                      # `make backup` output (gitignored)
```

## Prerequisites

- Docker Engine with the Compose v2 plugin (`docker compose version`)
- ~4GB RAM free for three MySQL instances plus ProxySQL
- Ports `3306`-`3308`, `6032`, `6033` free on your host

## Quickstart

```bash
make env      # copies .env.example -> .env (edit the passwords!)
make up       # builds the PXC image, starts everything, waits on health checks
make status   # container health + Galera status + ProxySQL routing table
```

`make up` runs `docker compose up -d`, which:

1. Builds the Ubuntu-based PXC image once (shared by all three `pxc-nodeN`
   services — Docker Compose recognizes the identical `image:` tag and only
   builds it once).
2. Starts `pxc-node1` with `BOOTSTRAP=true`. On an empty volume it
   initializes MySQL, seeds the `root`/app/ProxySQL-monitor accounts, loads
   [`sql/02-sample-schema.sql`](sql/02-sample-schema.sql), and starts a
   brand-new Galera cluster (`mysqld --wsrep-new-cluster`).
3. Starts `pxc-node2` only once `pxc-node1` is `healthy`, then `pxc-node3`
   only once `pxc-node2` is healthy — each one joins the existing cluster
   and receives a full State Snapshot Transfer (SST) via `xtrabackup-v2`
   from a donor.
4. Starts ProxySQL once all three PXC nodes are healthy.
5. Runs `proxysql-init`, a one-shot container that logs into ProxySQL's
   admin interface and loads the Galera-aware backend configuration from
   [`sql/proxysql_init.sql.template`](sql/proxysql_init.sql.template), then
   exits.

First boot takes 1-3 minutes (image build + two SSTs). Watch it happen with:

```bash
make logs             # everything
make logs-node2       # just the node currently joining
```

## Verifying the cluster

```bash
make status
```

```
== Galera cluster status (via pxc-node1) ==
Variable_name              Value
wsrep_cluster_size          3
wsrep_cluster_status        Primary
wsrep_connected             ON
wsrep_incoming_addresses    172.19.0.2:3306,172.19.0.3:3306,172.19.0.4:3306
wsrep_local_state_comment   Synced
wsrep_ready                 ON

== ProxySQL runtime backend view ==
hostgroup   srv_host    status    ConnUsed   ConnFree   Latency_us
10          pxc-node1   SHUNNED   0          0          366
10          pxc-node2   SHUNNED   0          0          1759
10          pxc-node3   ONLINE    0          0          424
11          pxc-node1   ONLINE    0          0          366
11          pxc-node2   ONLINE    0          0          1759
20          pxc-node1   ONLINE    0          0          366
20          pxc-node2   ONLINE    0          0          1759
20          pxc-node3   ONLINE    0          0          424
```

Read that ProxySQL table like this — it's the single most important thing
to understand about how this lab routes traffic:

| Hostgroup | Meaning | Who's `ONLINE` |
|---|---|---|
| `10` | **writer** — where INSERT/UPDATE/DELETE and non-SELECT go | exactly one node (ProxySQL elects it) |
| `11` | **backup writer** — standby, promoted automatically if the writer dies | the other two, healthy nodes |
| `20` | **reader** — where plain `SELECT` goes | all healthy nodes, including the writer |
| `30` | **offline** — node isn't part of the primary component | nobody, normally |

ProxySQL's [native Galera support](https://proxysql.com/blog/proxysql-native-support-for-galera-cluster/)
(the `mysql_galera_hostgroups` table loaded by `proxysql-init`) polls
`wsrep_local_state` on every backend every couple of seconds and moves
servers between these hostgroups automatically — that's what you're about
to watch happen in the failover test below.

## Connecting

**Through ProxySQL (the path a real application uses):**

```bash
make mysql-proxysql
# equivalent to:
docker exec -it proxysql mysql -h127.0.0.1 -P6033 -uappuser -p<MYSQL_PASSWORD> demo
```

or from your host, since port 6033 is published:

```bash
mysql -h127.0.0.1 -P6033 -uappuser -p demo
```

**Directly against one node** (bypasses ProxySQL and Galera's usual
single-writer discipline — useful for inspection, dangerous for real
writes since PXC is multi-master and doesn't serialize concurrent writers
for you):

```bash
make mysql-node1   # or mysql-node2 / mysql-node3
mysql -h127.0.0.1 -P3306 -uroot -p        # node1 from the host
mysql -h127.0.0.1 -P3307 -uroot -p        # node2
mysql -h127.0.0.1 -P3308 -uroot -p        # node3
```

**ProxySQL's admin interface** (query the routing tables directly):

```bash
make proxysql-admin
mysql> SELECT * FROM mysql_servers;
mysql> SELECT * FROM stats_mysql_connection_pool;
mysql> SELECT * FROM mysql_galera_hostgroups;
```

### Try the read/write split yourself

`proxysql-init` also loads two query rules: a plain `SELECT` is routed to
hostgroup `20` (readers); `SELECT ... FOR UPDATE` stays on hostgroup `10`
(the writer), since it takes a lock. Watch it happen:

```bash
source .env
docker exec -i proxysql mysql -h127.0.0.1 -P6032 -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" \
  -e "SELECT hostgroup, count_star, digest_text FROM stats_mysql_query_digest ORDER BY hostgroup;"
```

Run a few `SELECT * FROM demo.messages` through `make mysql-proxysql`, then
re-run the query above — you'll see the hits land on hostgroup `20`.

## Testing failover

```bash
make failover-test
```

This prints ProxySQL's current view, stops `pxc-node1` (whichever node
happens to be elected writer at the time might differ — check the output),
waits 10 seconds, and prints the view again. You'll see the stopped node
flip to `OFFLINE_HARD`/`SHUNNED` and traffic continue to flow to the
remaining two nodes — ProxySQL re-elects a writer automatically, with no
application-visible downtime beyond in-flight connections to the dead node.

Bring it back and watch it rejoin (it'll take an SST or IST depending on
how far behind it fell):

```bash
docker start pxc-node1
make logs-node1
make status   # once healthy again, it's back as a reader + backup writer
```

## Simulating a full outage and recovering

Galera's split-brain protection means if **every** node goes down, none of
them will restart into the cluster on their own — each one's
`grastate.dat` only trusts a restart if it was the *last* node to leave
gracefully (`safe_to_bootstrap: 1`); every other node has
`safe_to_bootstrap: 0` and will refuse to bootstrap a new cluster from
possibly-stale data. This is the real, standard Galera safety mechanism —
this lab doesn't paper over it.

1. **Simulate the outage:**
   ```bash
   docker compose stop pxc-node1 pxc-node2 pxc-node3
   ```

2. **Find the safest node to recover from** — the one with the highest
   `seqno` (or `safe_to_bootstrap: 1`) wins:
   ```bash
   for n in 1 2 3; do
     echo "--- pxc-node$n ---"
     docker run --rm -v pxc-lab_pxc-node${n}-data:/var/lib/mysql busybox \
       cat /var/lib/mysql/grastate.dat
   done
   ```

3. **Recover.** `make bootstrap-recover` automates the common case (recover
   from `pxc-node1`): it stops all three, drops a sentinel file into
   `pxc-node1`'s volume that tells the entrypoint to force
   `--wsrep-new-cluster` and flip `safe_to_bootstrap` to `1` itself, waits
   for it to become healthy, then starts the other two so they SST from it.
   ```bash
   make bootstrap-recover
   ```
   If a *different* node is actually the safest one, do it manually the
   same way `bootstrap-recover` does, against that node's volume:
   ```bash
   docker compose stop pxc-node1 pxc-node2 pxc-node3
   docker run --rm -v pxc-lab_pxc-node2-data:/var/lib/mysql busybox \
     touch /var/lib/mysql/.force-bootstrap
   docker compose up -d pxc-node2
   # wait for it to become healthy, then:
   docker compose up -d pxc-node1 pxc-node3
   ```

## Backups

```bash
make backup   # mysqldump --single-transaction --all-databases -> backups/backup-<timestamp>.sql
```

This is a logical backup taken from `pxc-node1` for convenience/portability
in a learning lab. For anything you'd actually restore under pressure,
look at [Percona XtraBackup](https://docs.percona.com/percona-xtrabackup/8.0/)
(already installed in the PXC image, since it's what SST uses under the
hood) for physical, non-blocking backups.

## Makefile reference

Run `make help` for the live list. Highlights:

| Target | What it does |
|---|---|
| `make up` / `make down` | start / stop everything (down keeps volumes) |
| `make status` | containers + Galera status + ProxySQL routing, all at once |
| `make logs`, `make logs-node1` | tail logs, everything or one service |
| `make mysql-proxysql` | mysql shell through ProxySQL (the app path) |
| `make mysql-node1/2/3` | mysql shell straight into one node |
| `make proxysql-admin` | mysql shell into ProxySQL's admin interface |
| `make failover-test` | stop node1, show ProxySQL react, tell you how to restart it |
| `make bootstrap-recover` | recover after a full cluster outage (see above) |
| `make backup` | logical backup of pxc-node1 into `./backups` |
| `make clean` | tear down and delete all data volumes (irreversible) |

## Environment variables (`.env`)

| Variable | Purpose |
|---|---|
| `CLUSTER_NAME` | Galera cluster name (`wsrep_cluster_name`) |
| `PXC_REPO` | Percona apt repo to install from — `pxc-84-lts` (default) or `pxc-80` |
| `PROXYSQL_VERSION` | `proxysql/proxysql` image tag — keep it `-debian` suffixed |
| `MYSQL_ROOT_PASSWORD` | root password, shared cluster-wide |
| `MYSQL_DATABASE` / `MYSQL_USER` / `MYSQL_PASSWORD` | demo app database + user, created on bootstrap |
| `PROXYSQL_ADMIN_USER` / `PROXYSQL_ADMIN_PASSWORD` | ProxySQL admin creds used over the docker network (must not be `admin`/`admin` — see below) |
| `PROXYSQL_MONITOR_USER` / `PROXYSQL_MONITOR_PASSWORD` | account ProxySQL uses to poll `wsrep_local_state` on each node |

SST credentials are **not** configured here — PXC 8.0+ generates an
internal SST user with a random password automatically for every state
transfer, so there's nothing to manage.

## Security notes (read this before you reuse any of this)

- **This lab disables TLS between PXC nodes and for SST traffic**
  (`pxc_encrypt_cluster_traffic=OFF` in the generated wsrep config). Each
  node auto-generates its own independent self-signed CA on
  initialization, so the certs don't chain to a shared trust root and
  Galera's/xtrabackup's TLS handshakes fail with `certificate signature
  failure` out of the box. A production cluster should provision one
  shared CA and a cert per node instead of disabling encryption. Client
  <-> server MySQL connections (port 3306/6033) still use TLS.
- `admin:admin` on ProxySQL's admin interface only ever works from
  `127.0.0.1` (ProxySQL hard-codes this) — that's why the container
  healthcheck uses it but `proxysql-init` and `make proxysql-admin` use the
  separate `PROXYSQL_ADMIN_USER`/`PASSWORD` from `.env` instead.
- Change every password in `.env` before you do anything beyond local
  learning with this. `.env` is gitignored; don't commit it.

## Troubleshooting

**A node is stuck restarting during `make up`.**
Check its log: `make logs-node2`. Almost always this is SST still in
progress — give it another minute, especially on first boot when the image
is also still building. If it's actually crash-looping, `docker exec
pxc-nodeN tail -100 /var/log/mysql/error.log` has the real Galera-level
error (the container's own stdout only carries the entrypoint's own
one-line status messages, not mysqld's log — mysqld logs to a file inside
the container).

**`wsrep_cluster_size` is `1` after startup, not `3`.**
`pxc-node2`/`pxc-node3` haven't finished joining yet, or one of them failed
its healthcheck and Compose never started it (`condition:
service_healthy` on `depends_on` is intentionally strict — a broken node2
will block node3 from even starting, rather than build a split cluster).

**`proxysql-init` failed / ProxySQL shows no backends.**
Re-run it: `docker compose up -d --force-recreate --no-deps proxysql-init`
— it's a one-shot job with a 15-attempt retry loop already built in for the
normal startup race, but you can always re-run it by hand; it's idempotent
(`DELETE` + `INSERT` on every table it touches).

**All ProxySQL hostgroups show a node `SHUNNED` with high `Latency_us` that
never recovers.**
Check `make cluster-status` — if `wsrep_ready` is `OFF` on that node, look
at its own error log; ProxySQL is accurately reporting a node that isn't
part of the primary component.

**I changed a password in `.env` and nothing picked it up.**
`make up` always runs `make render` first, which regenerates
`generated/proxysql.cnf` and `generated/proxysql_init.sql` from the
templates — but it does **not** retroactively change passwords already
baked into a running MySQL/ProxySQL instance. For a password change to
take effect, either apply it with SQL by hand, or `make clean && make up`
for a fresh cluster.

## Suggested experiments

This repo is meant to be broken on purpose. A few things worth trying:

- Run `make failover-test`, then while `pxc-node1` is down, insert rows
  through `make mysql-proxysql` and confirm they show up on all three nodes
  once it rejoins.
- Add a fourth query rule in `sql/proxysql_init.sql.template` and re-run
  `docker compose up -d --force-recreate --no-deps proxysql-init` to load it.
- `docker exec pxc-node2 rm -rf /var/lib/mysql/*` while it's stopped, then
  start it again and watch a full SST (rather than IST) happen in
  `make logs-node2`.
- Walk through the "simulating a full outage" section above for real —
  it's the single most useful Galera operations skill to practice.
- Point `wsrep_provider_options` in `docker/pxc/entrypoint.sh` at
  `gcache.size=1G` or other tuning knobs and see what changes in the logs.

## Cleanup

```bash
make down     # stop containers, keep data
make clean    # stop containers AND delete all volumes -- irreversible
```
