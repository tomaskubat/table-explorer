# Databázový klient pro macOS

## Build and test

The app targets Apple Silicon and macOS 26. Install the native build dependency with `brew install mariadb-connector-c`, then open [ConnectionBrowser.xcodeproj](ConnectionBrowser.xcodeproj) in Xcode and choose the **ConnectionBrowser** scheme and **My Mac**. Press ⌘R to run the app. The build embeds the MariaDB client and its TLS libraries. SQLite uses the macOS system library.

For the live MariaDB UI tests, start the disposable fixture before pressing ⌘U:

```sh
docker compose -f Tests/Fixtures/MariaDB/compose.yaml up -d --wait
```

The fixture listens on `127.0.0.1:33461` and initializes the `catalog` database from `seed.sql`. Stop it with `docker compose -f Tests/Fixtures/MariaDB/compose.yaml down`. Its data directory is temporary. Without the fixture, the MariaDB integration test is reported as skipped.
