# Databázový klient pro macOS

## Build and test

The app targets Apple Silicon and macOS 26. Install the native build dependency with `brew install mariadb-connector-c`, then open [ConnectionBrowser.xcodeproj](ConnectionBrowser.xcodeproj) in Xcode and choose the **ConnectionBrowser** scheme and **My Mac**. Press ⌘R to run the app. The build embeds the MariaDB client and its TLS libraries. SQLite uses the macOS system library.

For the live MariaDB UI tests, start the disposable fixture before pressing ⌘U:

```sh
docker compose -f Tests/Fixtures/MariaDB/compose.yaml up -d --wait
```

The fixture listens on `127.0.0.1:33461` and initializes the `catalog` database from `seed.sql`. Stop it with `docker compose -f Tests/Fixtures/MariaDB/compose.yaml down`. Its data directory is temporary. Without a fixture, its integration tests are reported as skipped.

For transport coverage, start a second server with `bash Tests/Fixtures/MariaDB/start-tls.sh` and run `python3 Tests/Fixtures/MariaDB/socket-relay.py` in another terminal while the TCP fixture is up. The TLS test checks rejection of an unknown CA and reads the negotiated cipher with the fixture CA. The socket test connects through a private Unix socket on the Mac to the Docker database. Close the relay with Ctrl-C and stop the TLS server with `docker compose -f Tests/Fixtures/MariaDB/secure-compose.yaml down`.
