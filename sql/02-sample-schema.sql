-- Demo schema, applied once to MYSQL_DATABASE on the bootstrap node during
-- the cluster's very first initialization. Galera replicates it to the
-- other two nodes automatically. Drop extra *.sql files in this directory
-- to have them applied the same way (only on a brand-new cluster).
CREATE TABLE IF NOT EXISTS messages (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    written_by VARCHAR(64)  NOT NULL,
    message    VARCHAR(255) NOT NULL,
    created_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

INSERT INTO messages (written_by, message) VALUES
    ('bootstrap', 'Hello from the PXC test lab -- this row was written during cluster init.');
