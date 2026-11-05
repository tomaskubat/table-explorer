# TableExplorer

TableExplorer is a SwiftUI database client for SQLite, MySQL, and MariaDB. It requires a Mac with Apple silicon running macOS 26 or later.

## Installation

1. Open the [latest GitHub release](https://github.com/tomaskubat/table-explorer/releases/latest) and download `TableExplorer-…-arm64.zip` from **Assets**.
2. Unzip the file, drag `TableExplorer.app` into **Applications**, and open it.

If macOS says it cannot verify the developer on first launch, go to **System Settings → Privacy & Security** and click **Open Anyway**. [Apple’s guide](https://support.apple.com/en-us/102445)

## Updates

TableExplorer automatically checks for updates and asks before installing a new version. To check manually, choose **TableExplorer → Check for Updates…**.

## Building a release

Run `make release` on the signing Mac. Release builds must match the [TableExplorer code signing certificate](Configuration/table-explorer-signing.pem). Sparkle uses a separate key to verify updates. Installing the app on another Mac does not require either private key.

The hosted release workflow requires the optional `TABLEEXPLORER_SIGNING_P12` (base64-encoded, encrypted PKCS#12) and `TABLEEXPLORER_SIGNING_PASSWORD` secrets in addition to the Sparkle secret. Without them, use the local release target.
