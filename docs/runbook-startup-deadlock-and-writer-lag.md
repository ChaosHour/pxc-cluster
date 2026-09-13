# Runbook: startup deadlock & ProxySQL writer-hostgroup lag

Manual, step-by-step versions of the two issues hit while bringing this lab
up, for when you want to do it by hand instead of via `make
bootstrap-recover` / `make status`. See also the README's own
["Simulating a full outage and recovering"](../README.md#simulating-a-full-outage-and-recovering)
and ["Troubleshooting"](../README.md#troubleshooting) sections, which cover
the same ground more briefly.

## Issue 1: `make up` hangs / `pxc-node1` stuck `unhealthy`

### Symptom

```
docker compose up -d
[+] up 1/1
 ✘ Container pxc-node1 Error dependency pxc-node1 failed to start
dependency failed to start: container pxc-node1 is unhealthy
```

or `docker compose ps` shows `pxc-node1` as `Up (unhealthy)` indefinitely,
while `pxc-node2`/`pxc-node3` sit at `Created` and never start.

### Why it happens

`pxc-node1`'s data volume (`pxc-lab_pxc-node1-data`) already has data on it
from a previous run — i.e. this isn't a truly fresh cluster. The
entrypoint (`docker/pxc/entrypoint.sh`) only auto-bootstraps a brand-new
cluster (`--wsrep-new-cluster`) when the datadir is *empty*; with existing
data it just starts `mysqld` normally, which tries to join via
`gcomm://pxc-node1,pxc-node2,pxc-node3`. Since node2/node3 haven't started,
node1 sits in `NON-PRIMARY` waiting for peers that will never show up —
its healthcheck (`wsrep_ready = ON`) never passes.

Meanwhile `pxc-node2` and `pxc-node3` both have `depends_on: { pxc-node1:
{ condition: service_healthy } }`, so Compose refuses to start them until
node1 reports healthy. Deadlock: node1 waits on node2/3, node2/3 wait on
node1.

### Diagnose it

```bash
# confirm node1 is up-but-unhealthy while node2/3 never started
docker compose ps -a

# confirm it's waiting on peers that don't exist yet
docker logs pxc-node1 --tail 50
#   look for: "joining pxc-cluster via gcomm://pxc-node1,pxc-node2,pxc-node3"
#   and: "Failed to resolve tcp://pxc-node2:4567" / "...pxc-node3:4567"
#   and a view showing "status: non-primary"

# confirm the healthcheck is actually failing
docker inspect pxc-node1 --format='{{json .State.Health}}'
```

### Fix it manually

This is exactly the "all nodes down" disaster-recovery case, just reached
via a hung first boot instead of a real outage. Force-bootstrap a new
cluster off `pxc-node1`'s existing data, then bring the rest up once it's
healthy:

```bash
# 1. Stop everything cleanly (keeps volumes)
docker compose down

# 2. Drop the sentinel file the entrypoint looks for on next boot.
#    It makes the entrypoint start mysqld with --wsrep-new-cluster and,
#    if needed, flips grastate.dat's safe_to_bootstrap to 1 itself.
docker run --rm -v pxc-lab_pxc-node1-data:/var/lib/mysql busybox \
  touch /var/lib/mysql/.force-bootstrap

# 3. Start only pxc-node1 and wait for it to go healthy
docker compose up -d pxc-node1

for i in $(seq 1 30); do
  hstatus=$(docker inspect -f '{{.State.Health.Status}}' pxc-node1)
  echo "[$i] $hstatus"
  [ "$hstatus" = "healthy" ] && break
  sleep 3
done

# sanity check: log should show the forced-bootstrap path, not gcomm join
docker logs pxc-node1 --tail 10
#   expect: "forced bootstrap requested: starting a new cluster from this node's data"
#           "starting mysqld with --wsrep-new-cluster (bootstrapping pxc-cluster)"

# 4. Now that node1 is healthy, bring up everything else normally --
#    node2/node3 will SST from node1, then proxysql/proxysql-init follow.
docker compose up -d
```

If `pxc-node1` isn't actually the node with the most recent data (check
`grastate.dat`'s `seqno` on each node first, per the README), do the same
three steps against whichever node's volume is safest instead of node1's.

### Confirm it's actually fixed

```bash
docker compose ps -a
# all 5 containers should show (healthy) / Exited (0) for proxysql-init

docker exec pxc-node1 mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e \
  "SHOW STATUS WHERE Variable_name IN
   ('wsrep_cluster_size','wsrep_cluster_status','wsrep_ready');"
# expect: wsrep_cluster_size=3, wsrep_cluster_status=Primary, wsrep_ready=ON
```

(Or just `make status`, which runs both of the above plus the ProxySQL
view.)

---

## Issue 2: ProxySQL shows a node `OFFLINE_HARD` in the reader hostgroup

### Symptom

```
docker exec proxysql mysql -h127.0.0.1 -P6032 -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" -e \
  "SELECT hostgroup, srv_host, status, ConnUsed, ConnFree, Latency_us
   FROM stats_mysql_connection_pool ORDER BY hostgroup, srv_host;"
```

shows the currently-elected writer node (e.g. `pxc-node3`) as `ONLINE` in
hostgroup `10` (writer) but `OFFLINE_HARD` in hostgroup `20` (reader),
even though `mysql_galera_hostgroups.writer_is_also_reader = 1` says it
should also be an `ONLINE` reader.

### Why it happens

ProxySQL's native Galera checker updates a node's writer-hostgroup row and
its reader-hostgroup mirror row (the `writer_is_also_reader` row) in two
separate steps, not atomically. Right after a writer election, there's a
brief window — typically resolved within one or two
`monitor_galera_healthcheck_interval` cycles (2s by default in this lab's
`proxysql.cnf.template`) — where the reader-side row hasn't caught up yet.
It is *not* evidence the node is actually down.

### Diagnose it (don't just wait blindly — confirm it's transient, not real)

```bash
set -a; source .env; set +a

# 1. Is the underlying node actually healthy?
docker exec pxc-node3 mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e \
  "SHOW VARIABLES LIKE 'read_only';
   SHOW STATUS LIKE 'wsrep_local_state_comment';
   SHOW STATUS LIKE 'wsrep_local_state';"
# expect: read_only=OFF, wsrep_local_state_comment=Synced, wsrep_local_state=4
# If this node is NOT Synced, that's a real problem -- stop here and
# investigate the node itself (docker logs / its own error log), don't
# treat it as the cosmetic lag below.

# 2. Confirm the config actually expects it to be a reader too
docker exec proxysql mysql -h127.0.0.1 -P6032 -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" -e \
  "SELECT writer_hostgroup, reader_hostgroup, writer_is_also_reader
   FROM runtime_mysql_galera_hostgroups;"
# writer_is_also_reader should be 1 (or 2) -- if it's 0, OFFLINE_HARD in
# the reader hostgroup for the writer is *expected*, not a bug.

# 3. Look at ProxySQL's own reasoning in its log
docker logs proxysql --tail 200 | grep -i -E 'node3|galera|writer'
#   look for a line like:
#   "update_galera_set_writer(): [WARNING] Galera: setting host
#    pxc-node3:3306 as writer"
#   followed shortly by its HG20 row being recreated with a new status.
```

### Fix it

There's nothing to fix by hand — forcing it would just fight the
checker. Just re-poll the runtime view and confirm it clears on its own:

```bash
watch -n2 'docker exec proxysql mysql -h127.0.0.1 -P6032 \
  -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" -e \
  "SELECT hostgroup, srv_host, status FROM stats_mysql_connection_pool
   ORDER BY hostgroup, srv_host;"'
```

(or just `make proxysql-status` a couple of times a few seconds apart). It
should flip to `ONLINE` within a few seconds.

### If it does NOT clear after ~30s

That's no longer this cosmetic case — treat it as the README's
"SHUNNED with high latency that never recovers" scenario instead: check
`make cluster-status` for `wsrep_ready` on that node, and its own error
log for the real Galera-level problem.
