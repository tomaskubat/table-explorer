-- Dedicated account for the account-management UI test on the TLS fixture.
CREATE USER 'fixture_admin'@'%' IDENTIFIED BY 'fixture-admin-only' REQUIRE SSL;
GRANT CREATE USER ON *.* TO 'fixture_admin'@'%';
GRANT SELECT ON mysql.* TO 'fixture_admin'@'%';
GRANT ALL PRIVILEGES ON `backup\_demo`.* TO 'fixture_admin'@'%' WITH GRANT OPTION;
