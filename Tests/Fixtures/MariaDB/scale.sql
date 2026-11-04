USE catalog;
CREATE TABLE IF NOT EXISTS million_rows (
    id INT NOT NULL PRIMARY KEY,
    label VARCHAR(20) NOT NULL
) ENGINE=InnoDB;
INSERT IGNORE INTO million_rows (id, label)
SELECT seq, CONCAT('row-', LPAD(seq, 7, '0')) FROM seq_1_to_1000000;
