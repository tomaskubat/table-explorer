# Connection Browser

## Build and test

The app targets Apple Silicon and macOS 26. Install the native build dependency with `brew install mariadb-connector-c`, then open [ConnectionBrowser.xcodeproj](ConnectionBrowser.xcodeproj) in Xcode and choose the **ConnectionBrowser** scheme and **My Mac**. Press ⌘R to run the app. The build embeds the MariaDB client and its TLS libraries. SQLite uses the macOS system library. Profiles are saved in Application Support by default. Set `CONNECTION_BROWSER_LIBRARY` to an absolute directory to use a separate library for testing.

For the live MariaDB UI tests, start the disposable fixture before pressing ⌘U:

```sh
docker compose -f Tests/Fixtures/MariaDB/compose.yaml up -d --wait
```

The primary fixture contains the `country` sample and a physical `million_rows` table for pagination tests. It listens on `127.0.0.1:33461` and initializes the `catalog` database from `seed.sql`. Stop it with `docker compose -f Tests/Fixtures/MariaDB/compose.yaml down`. Its data directory is temporary. Without a fixture, its integration tests are reported as skipped.

For transport coverage, start a second server with `bash Tests/Fixtures/MariaDB/start-tls.sh` and run `python3 Tests/Fixtures/MariaDB/socket-relay.py` in another terminal while the TCP fixture is up. The TLS test checks rejection of an unknown CA and reads the negotiated cipher with the fixture CA. The socket test connects through a private Unix socket on the Mac to the Docker database. Close the relay with Ctrl-C and stop the TLS server with `docker compose -f Tests/Fixtures/MariaDB/secure-compose.yaml down`.

For the SSH tests, start the primary MariaDB fixture, then run `sh Tests/Fixtures/SSH/start-ssh.sh`. The bastion is bound to `127.0.0.1:33463` and only permits forwarding to the fixture database. It uses dedicated keys under `.build/SSHFixture`. When the TLS fixture is running, a second bastion on port 33464 also checks the database certificate inside the tunnel. Stop both with `docker compose -f Tests/Fixtures/SSH/compose.yaml --profile tls down`.

The TLS fixture includes the small `backup_demo` database and a separate `fixture_admin` account for the account-management tests. The ordinary `browser` account remains suitable for testing denied server privileges. The backup test needs an arm64 `mariadb-dump` and `mariadb`, or `mysqldump` and `mysql`. The app searches Homebrew paths. You can also select the executables in Settings. SQLite backups use the system SQLite Online Backup API.

With all fixtures running, execute the complete UI suite from the project directory.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ConnectionBrowser.xcodeproj -scheme ConnectionBrowser \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO
```

To run just the screenshot comparison while the regular app is open, use a separate build directory and bundle identifier. The test creates a temporary sample database and still uses the Mac’s foreground keyboard and mouse.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ConnectionBrowser.xcodeproj -scheme ConnectionBrowser -configuration Release \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -derivedDataPath .build/VisualChecks CONNECTION_BROWSER_BUNDLE_SUFFIX=.visual \
  -only-testing:ConnectionBrowserUITests/WorkspaceLayoutTests
```

## Files and sessions

File → Open SQL File opens a document from Saved Connections or a query tab in the active workspace. ⌘S saves the text in an SQL editor. In a data tab it opens the pending-changes preview. In a workspace, ⌘W closes the active tab; closing the last tab leaves the connection open. The window close button closes the workspace. Window → Show Workspaces switches between open sessions.

Run Options → Enable Query Parameters turns on SQL expressions in the editor. The default placeholder is `:name`. Repeated names share a value, and each positional `?` has its own value. Review SQL shows the expanded command before execution. Values stay in the current tab. History and favorites keep the template.

A click in the grid selects a row and marks the active column. Closing the cell editor returns to that cell. Return starts inline editing when the column is writable.

After reconnecting, File → Recover SQL Draft opens locally recovered text for the same profile and database. Running the text requires an explicit command. Discarding or saving a tab clears its recovery copy. Passwords for MariaDB and SSH use separate Keychain entries. Profile exports omit those passwords and any bootstrap script.

SQLite ověříš příkazem `Scripts/check-sqlite.sh`. Skript si vytvoří dočasnou testovací databázi.

Zdroj [ikony aplikace](Design/Database.svg) lze upravit jako SVG. Příkaz `Scripts/make-app-icon.sh` z něj vytvoří macOS prostředek, který Xcode přibalí do aplikace.
