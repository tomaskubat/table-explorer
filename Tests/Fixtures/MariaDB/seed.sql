USE catalog;
CREATE TABLE country (
    code CHAR(2) NOT NULL PRIMARY KEY,
    name VARCHAR(80) NOT NULL,
    note TEXT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
INSERT INTO country (code, name, note) VALUES
    ('CZ', 'Czechia', NULL), ('AT', 'Austria', ''), ('SK', 'Slovakia', 'Bratislava');
CREATE VIEW country_names AS SELECT code, name FROM country;
