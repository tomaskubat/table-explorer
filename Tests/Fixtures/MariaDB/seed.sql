USE catalog;
CREATE TABLE country (
    code CHAR(2) NOT NULL PRIMARY KEY,
    name VARCHAR(80) NOT NULL,
    note TEXT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
INSERT INTO country (code, name, note) VALUES
    ('CZ', 'Czechia', NULL), ('AT', 'Austria', ''), ('SK', 'Slovakia', 'Bratislava');
CREATE VIEW country_names AS SELECT code, name FROM country;
CREATE PROCEDURE list_countries() READS SQL DATA SELECT code, name FROM country ORDER BY code;
CREATE DATABASE IF NOT EXISTS backup_demo;
GRANT ALL PRIVILEGES ON backup_demo.* TO 'browser'@'%';
CREATE TABLE backup_demo.notes (id INT PRIMARY KEY, body VARCHAR(80) NOT NULL) ENGINE=InnoDB;
INSERT INTO backup_demo.notes VALUES (1, 'Original');
