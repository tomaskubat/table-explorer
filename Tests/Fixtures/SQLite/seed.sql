PRAGMA foreign_keys = ON;
BEGIN;

CREATE TABLE zeme (
    kod TEXT PRIMARY KEY,
    nazev TEXT NOT NULL
);
CREATE TABLE mesto (
    id INTEGER PRIMARY KEY,
    nazev TEXT NOT NULL,
    kod_zeme TEXT NOT NULL REFERENCES zeme(kod),
    poznamka TEXT
);
CREATE INDEX ix_mesto_zeme ON mesto(kod_zeme);
CREATE VIEW v_mesta (mesto, zeme) AS
    SELECT mesto.nazev, zeme.nazev
    FROM mesto JOIN zeme ON mesto.kod_zeme = zeme.kod;

INSERT INTO zeme (kod, nazev) VALUES
    ('CZ', 'Česko'), ('SK', 'Slovensko'), ('AT', 'Rakousko');
INSERT INTO mesto (id, nazev, kod_zeme, poznamka) VALUES
    (1, 'Brno', 'CZ', NULL),
    (2, 'Košice', 'SK', 'Východ'),
    (3, 'Graz', 'AT', '');
COMMIT;
