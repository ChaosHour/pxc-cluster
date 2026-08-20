SHELL := /bin/bash
COMPOSE := docker compose
ENV_FILE := .env

.PHONY: help env render build up down restart stop start clean logs \
        logs-node1 logs-node2 logs-node3 logs-proxysql ps status cluster-status \
        proxysql-status mysql-node1 mysql-node2 mysql-node3 mysql-proxysql \
        proxysql-admin failover-test bootstrap-recover backup

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

env: ## Create .env from .env.example if it doesn't exist yet
	@if [ -f $(ENV_FILE) ]; then \
		echo ".env already exists, leaving it alone"; \
	else \
		cp .env.example $(ENV_FILE); \
		echo "Created .env from .env.example -- edit the passwords before running 'make up'"; \
	fi

render: env ## Render proxysql.cnf / proxysql_init.sql from templates using .env
	@mkdir -p generated
	@set -a; source $(ENV_FILE); set +a; \
	sed \
		-e "s|__PROXYSQL_ADMIN_USER__|$$PROXYSQL_ADMIN_USER|g" \
		-e "s|__PROXYSQL_ADMIN_PASSWORD__|$$PROXYSQL_ADMIN_PASSWORD|g" \
		-e "s|__PROXYSQL_MONITOR_USER__|$$PROXYSQL_MONITOR_USER|g" \
		-e "s|__PROXYSQL_MONITOR_PASSWORD__|$$PROXYSQL_MONITOR_PASSWORD|g" \
		proxysql/proxysql.cnf.template > generated/proxysql.cnf; \
	sed \
		-e "s|__MYSQL_USER__|$$MYSQL_USER|g" \
		-e "s|__MYSQL_PASSWORD__|$$MYSQL_PASSWORD|g" \
		-e "s|__CLUSTER_NAME__|$$CLUSTER_NAME|g" \
		sql/proxysql_init.sql.template > generated/proxysql_init.sql
	@echo "Rendered generated/proxysql.cnf and generated/proxysql_init.sql"

build: render ## Build the custom Ubuntu-based PXC image
	$(COMPOSE) build

up: render ## Start (or resume) the 3-node PXC cluster + ProxySQL
	$(COMPOSE) up -d
	@echo ""
	@echo "Bringing up pxc-node1, pxc-node2, pxc-node3, proxysql, proxysql-init..."
	@echo "This can take a couple of minutes on first boot (image build + SST)."
	@echo "Watch progress with:  make logs"
	@echo "Check cluster health with:  make status"

down: ## Stop and remove containers (data volumes are kept)
	$(COMPOSE) down

stop: ## Stop containers without removing them
	$(COMPOSE) stop

start: ## Start previously-stopped containers
	$(COMPOSE) start

restart: ## Restart all containers
	$(COMPOSE) restart

clean: ## Stop everything and delete all data volumes (irreversible)
	$(COMPOSE) down -v
	rm -rf generated/*.cnf generated/*.sql

logs: ## Tail logs from every container
	$(COMPOSE) logs -f

logs-node1: ## Tail logs from pxc-node1
	$(COMPOSE) logs -f pxc-node1

logs-node2: ## Tail logs from pxc-node2
	$(COMPOSE) logs -f pxc-node2

logs-node3: ## Tail logs from pxc-node3
	$(COMPOSE) logs -f pxc-node3

logs-proxysql: ## Tail logs from ProxySQL
	$(COMPOSE) logs -f proxysql

ps: ## Show container status
	$(COMPOSE) ps

status: ps cluster-status proxysql-status ## Show container, Galera, and ProxySQL status together

cluster-status: ## Query wsrep status on pxc-node1
	@set -a; source $(ENV_FILE); set +a; \
	echo ""; echo "== Galera cluster status (via pxc-node1) =="; \
	docker exec pxc-node1 mysql -uroot -p"$$MYSQL_ROOT_PASSWORD" -e \
		"SHOW STATUS WHERE Variable_name IN ('wsrep_cluster_size','wsrep_cluster_status','wsrep_ready','wsrep_local_state_comment','wsrep_incoming_addresses','wsrep_connected');"

proxysql-status: ## Show how ProxySQL currently sees the backend servers
	@set -a; source $(ENV_FILE); set +a; \
	echo ""; echo "== ProxySQL runtime backend view =="; \
	docker exec proxysql mysql -h127.0.0.1 -P6032 -u"$$PROXYSQL_ADMIN_USER" -p"$$PROXYSQL_ADMIN_PASSWORD" -e \
		"SELECT hostgroup, srv_host, status, ConnUsed, ConnFree, Latency_us FROM stats_mysql_connection_pool ORDER BY hostgroup, srv_host;"

mysql-node1: ## Open a mysql shell directly on pxc-node1 (bypasses ProxySQL)
	@set -a; source $(ENV_FILE); set +a; docker exec -it pxc-node1 mysql -uroot -p"$$MYSQL_ROOT_PASSWORD"

mysql-node2: ## Open a mysql shell directly on pxc-node2 (bypasses ProxySQL)
	@set -a; source $(ENV_FILE); set +a; docker exec -it pxc-node2 mysql -uroot -p"$$MYSQL_ROOT_PASSWORD"

mysql-node3: ## Open a mysql shell directly on pxc-node3 (bypasses ProxySQL)
	@set -a; source $(ENV_FILE); set +a; docker exec -it pxc-node3 mysql -uroot -p"$$MYSQL_ROOT_PASSWORD"

mysql-proxysql: ## Open a mysql shell through ProxySQL as the app user (the "real" traffic path)
	@set -a; source $(ENV_FILE); set +a; docker exec -it proxysql mysql -h127.0.0.1 -P6033 -u"$$MYSQL_USER" -p"$$MYSQL_PASSWORD" "$$MYSQL_DATABASE"

proxysql-admin: ## Open a mysql shell on ProxySQL's admin interface (port 6032)
	@set -a; source $(ENV_FILE); set +a; docker exec -it proxysql mysql -h127.0.0.1 -P6032 -u"$$PROXYSQL_ADMIN_USER" -p"$$PROXYSQL_ADMIN_PASSWORD"

failover-test: ## Kill pxc-node1 to demonstrate ProxySQL failing over to another writer
	@echo "Current writer according to ProxySQL:"; \
	$(MAKE) --no-print-directory proxysql-status
	@echo ""; echo "Stopping pxc-node1..."; docker stop pxc-node1
	@echo "Waiting 10s for ProxySQL to detect the change..."; sleep 10
	@$(MAKE) --no-print-directory proxysql-status
	@echo ""; echo "Bring it back with:  docker start pxc-node1"

bootstrap-recover: ## Force-bootstrap a new cluster from pxc-node1 after ALL nodes went down (see README 'Disaster recovery')
	@echo "This assumes pxc-node1 holds the most recent data (check grastate.dat"; \
	echo "seqno on all three nodes first -- see the README before running this"; \
	echo "on a real incident, not just this lab)."; \
	read -p "Continue and force-bootstrap from pxc-node1? [y/N] " ans; [ "$$ans" = "y" ] || exit 1
	$(COMPOSE) stop pxc-node1 pxc-node2 pxc-node3
	docker run --rm -v pxc-lab_pxc-node1-data:/var/lib/mysql busybox touch /var/lib/mysql/.force-bootstrap
	$(COMPOSE) up -d pxc-node1
	@echo "Waiting for pxc-node1 to become healthy..."
	@until [ "$$(docker inspect -f '{{.State.Health.Status}}' pxc-node1)" = "healthy" ]; do sleep 2; done
	$(COMPOSE) up -d pxc-node2 pxc-node3

backup: ## Take a logical backup (mysqldump) of pxc-node1 into ./backups
	@set -a; source $(ENV_FILE); set +a; \
	mkdir -p backups; \
	STAMP=$$(date +%Y%m%d-%H%M%S); \
	docker exec pxc-node1 mysqldump -uroot -p"$$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers --all-databases > backups/backup-$$STAMP.sql; \
	echo "Wrote backups/backup-$$STAMP.sql"
