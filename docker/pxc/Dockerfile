# Percona XtraDB Cluster 8.4 (LTS) on Ubuntu 24.04 (Noble)
#
# Percona's official percona/percona-xtradb-cluster images are built on
# Red Hat UBI9-minimal. This Dockerfile builds the same product from
# Percona's official apt repository on top of Ubuntu, so every container
# in this lab runs on Ubuntu/Debian.
FROM ubuntu:24.04

ARG PXC_REPO=pxc-84-lts
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        wget \
        gnupg2 \
        lsb-release \
        ca-certificates \
        curl \
        socat \
        pv \
    ; \
    wget -q https://repo.percona.com/apt/percona-release_latest.generic_all.deb -O /tmp/percona-release.deb; \
    dpkg -i /tmp/percona-release.deb; \
    rm -f /tmp/percona-release.deb; \
    apt-get update; \
    percona-release setup -y "${PXC_REPO}"; \
    apt-get update; \
    apt-get install -y --no-install-recommends percona-xtradb-cluster percona-xtrabackup; \
    apt-get purge -y --auto-remove wget gnupg2; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*; \
    # Container-controlled datadir: the entrypoint initializes it on first boot.
    rm -rf /var/lib/mysql/*; \
    mkdir -p /var/lib/mysql /var/run/mysqld /docker-entrypoint-initdb.d; \
    chown -R mysql:mysql /var/lib/mysql /var/run/mysqld; \
    # Never let apt/dpkg start mysqld directly; the entrypoint owns the process.
    sed -i 's/^bind-address/#bind-address/' /etc/mysql/mysql.conf.d/mysqld.cnf || true; \
    sed -i 's/^mysqlx-bind-address/#mysqlx-bind-address/' /etc/mysql/mysql.conf.d/mysqld.cnf || true

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME ["/var/lib/mysql"]
EXPOSE 3306 4444 4567 4568

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["mysqld"]
