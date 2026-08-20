#!/usr/bin/env bash
# Entrypoint for the custom Ubuntu-based Percona XtraDB Cluster image.
#
# Responsibilities:
#   1. On a brand-new (empty) datadir, initialize MySQL's system tables.
#   2. On the designated bootstrap node's very first boot, seed root/app/
#      monitor users and start a brand-new Galera cluster
#      (--wsrep-new-cluster). SST credentials are generated internally by
#      PXC itself (PXC 8.0+), so there's no SST user to create here.
#   3. On every other boot, write the wsrep config and start mysqld so it
#      joins (or rejoins) the existing cluster via gcomm://.
set -Eeuo pipefail

DATADIR=/var/lib/mysql
SOCKET=/var/run/mysqld/mysqld.sock
NODE_NAME="$(hostname)"

: "${CLUSTER_NAME:?CLUSTER_NAME is required}"
: "${CLUSTER_MEMBERS:?CLUSTER_MEMBERS is required (comma-separated list of all node hostnames)}"
: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is required}"
: "${MYSQL_DATABASE:?MYSQL_DATABASE is required}"
: "${MYSQL_USER:?MYSQL_USER is required}"
: "${MYSQL_PASSWORD:?MYSQL_PASSWORD is required}"
: "${PROXYSQL_MONITOR_USER:?PROXYSQL_MONITOR_USER is required}"
: "${PROXYSQL_MONITOR_PASSWORD:?PROXYSQL_MONITOR_PASSWORD is required}"

BOOTSTRAP="${BOOTSTRAP:-false}"
FORCE_BOOTSTRAP="${FORCE_BOOTSTRAP:-false}"

log() { echo "[entrypoint] $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }

if [ "$1" != "mysqld" ]; then
    exec "$@"
fi

GALERA_LIB="$(find /usr/lib -iname 'libgalera_smm.so' 2>/dev/null | head -n1)"
if [ -z "$GALERA_LIB" ]; then
    log "FATAL: could not locate libgalera_smm.so"
    exit 1
fi

NODE_IP="$(hostname -I | awk '{print $1}')"
# Deterministic, unique-enough numeric server_id derived from the hostname.
SERVER_ID="$(( (0x$(echo -n "$NODE_NAME" | md5sum | cut -c1-7)) % 4000000000 + 1 ))"

mkdir -p /var/run/mysqld
chown -R mysql:mysql /var/run/mysqld

# NOTE: wsrep_* variables (in particular wsrep_sst_auth) are not recognized
# by `mysqld --initialize`, which runs with the wsrep provider forced to
# "none". The wsrep config is written further down, after any first-time
# initialization, and just before the real (replicating) mysqld start.
WSREP_CNF=/etc/mysql/conf.d/zz-wsrep.cnf

FRESH_DATADIR=false
if [ ! -d "${DATADIR}/mysql" ]; then
    FRESH_DATADIR=true
fi

if [ "$FRESH_DATADIR" = "true" ]; then
    log "empty datadir detected, running mysqld --initialize-insecure"
    mysqld --user=mysql --datadir="$DATADIR" --initialize-insecure

    if [ "$BOOTSTRAP" = "true" ]; then
        log "this is the designated bootstrap node; seeding accounts before first cluster start"
        mysqld --user=mysql --datadir="$DATADIR" --socket="$SOCKET" \
            --skip-networking --wsrep-provider=none \
            --pid-file=/var/run/mysqld/mysqld-init.pid &
        INIT_PID=$!

        for _ in $(seq 1 60); do
            if mysqladmin --socket="$SOCKET" ping >/dev/null 2>&1; then
                break
            fi
            sleep 1
        done

        mysql --socket="$SOCKET" -uroot <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\`;
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';
CREATE USER IF NOT EXISTS '${PROXYSQL_MONITOR_USER}'@'%' IDENTIFIED BY '${PROXYSQL_MONITOR_PASSWORD}';
GRANT USAGE, REPLICATION CLIENT ON *.* TO '${PROXYSQL_MONITOR_USER}'@'%';
FLUSH PRIVILEGES;
SQL

        shopt -s nullglob
        for f in /docker-entrypoint-initdb.d/*.sql; do
            log "applying init script: $f"
            mysql --socket="$SOCKET" -uroot -p"${MYSQL_ROOT_PASSWORD}" "${MYSQL_DATABASE}" < "$f"
        done
        shopt -u nullglob

        log "shutting down temporary mysqld used for seeding"
        mysqladmin --socket="$SOCKET" -uroot -p"${MYSQL_ROOT_PASSWORD}" shutdown
        wait "$INIT_PID" 2>/dev/null || true
    else
        log "join node with a fresh datadir; skipping account seeding (SST will replace this data)"
    fi
fi

cat > "$WSREP_CNF" <<EOF
[mysqld]
server_id=${SERVER_ID}
bind-address=0.0.0.0
wsrep_provider=${GALERA_LIB}
wsrep_cluster_name=${CLUSTER_NAME}
wsrep_cluster_address=gcomm://${CLUSTER_MEMBERS}
wsrep_node_address=${NODE_IP}
wsrep_node_name=${NODE_NAME}
wsrep_sst_method=xtrabackup-v2
# Each node auto-generates its own self-signed CA on --initialize, so the
# stock certs don't chain to a common trust root: both Galera's own TLS
# ("certificate signature failure") and xtrabackup-v2's SST transport TLS
# fail the same way. pxc-encrypt-cluster-traffic (default ON in PXC 8.4)
# is the single switch that covers both, so cluster/SST traffic is left
# unencrypted here; client<->server MySQL connections still use TLS. For a
# production cluster, provision one shared CA and a cert per node instead.
pxc_encrypt_cluster_traffic=OFF
wsrep_provider_options="socket.ssl=no"
binlog_format=ROW
default_storage_engine=InnoDB
innodb_autoinc_lock_mode=2
pxc_strict_mode=ENFORCING
EOF
log "wrote ${WSREP_CNF} (node=${NODE_NAME} ip=${NODE_IP} server_id=${SERVER_ID})"

START_NEW_CLUSTER=false
if [ "$FORCE_BOOTSTRAP" = "true" ] || [ -f "${DATADIR}/.force-bootstrap" ]; then
    log "forced bootstrap requested: starting a new cluster from this node's data"
    START_NEW_CLUSTER=true
    rm -f "${DATADIR}/.force-bootstrap" "${DATADIR}/gvwstate.dat"
    # Galera refuses to bootstrap from a node that wasn't the last one to
    # leave the cluster (grastate.dat: safe_to_bootstrap: 0) as a
    # split-brain guard. FORCE_BOOTSTRAP is an explicit human decision to
    # override that guard, so flip the flag ourselves rather than making
    # the operator hand-edit the volume.
    if [ -f "${DATADIR}/grastate.dat" ]; then
        sed -i 's/^safe_to_bootstrap:.*/safe_to_bootstrap: 1/' "${DATADIR}/grastate.dat"
    fi
elif [ "$BOOTSTRAP" = "true" ] && [ "$FRESH_DATADIR" = "true" ]; then
    START_NEW_CLUSTER=true
fi

if [ "$START_NEW_CLUSTER" = "true" ]; then
    log "starting mysqld with --wsrep-new-cluster (bootstrapping ${CLUSTER_NAME})"
    exec mysqld --user=mysql --datadir="$DATADIR" --wsrep-new-cluster
else
    log "starting mysqld, joining ${CLUSTER_NAME} via gcomm://${CLUSTER_MEMBERS}"
    exec mysqld --user=mysql --datadir="$DATADIR"
fi
