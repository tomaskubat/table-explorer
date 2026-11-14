# TableExplorer

TableExplorer is a SwiftUI database client for SQLite, MySQL, and MariaDB. It requires a Mac with Apple silicon running macOS 26 or later.

## Installation

1. Open the [latest GitHub release](https://github.com/tomaskubat/table-explorer/releases/latest) and download `TableExplorer-…-arm64.zip` from **Assets**.
2. Unzip the file, drag `TableExplorer.app` into **Applications**, and open it.

If macOS says it cannot verify the developer on first launch, go to **System Settings → Privacy & Security** and click **Open Anyway**. [Apple’s guide](https://support.apple.com/en-us/102445)

## Updates

TableExplorer automatically checks for updates and asks before installing a new version. To check manually, choose **TableExplorer → Check for Updates…**.

New versions retain the same signing certificate and application identifier, so Keychain can recognize them as the same app. Each Mac grants access to its own saved passwords independently. Installing an update does not require the signing private key; it stays on the build Mac. The app does not synchronize database or SSH passwords between Macs.

## Local builds

Run `make build` to build and verify the app, or `make run` to build, verify and open it. The app is written to `.build/local/Build/Products/Debug/TableExplorer.app`.

Xcode and command-line builds use [CodeSigning.xcconfig](Configuration/CodeSigning.xcconfig) to sign with the same certificate as releases. Building requires the matching certificate and private key in Keychain. When switching from an older ad-hoc build, existing saved passwords may need a one-time **Always Allow** approval for the signed app.

Run `Tests/QA/local-signing.sh .build/local/Build/Products/Debug/TableExplorer.app` to check signing continuity across versions and rejection of ad-hoc signatures. An optional second argument checks compatibility with an unpacked release app.

## Building a release

Run `make release` on the signing Mac. Release builds must match the [TableExplorer code signing certificate](Configuration/table-explorer-signing.pem). Sparkle uses a separate key to verify updates. Installing the app on another Mac does not require either private key.

The hosted release workflow requires the optional `TABLEEXPLORER_SIGNING_P12` (base64-encoded, encrypted PKCS#12) and `TABLEEXPLORER_SIGNING_PASSWORD` secrets in addition to the Sparkle secret. Without them, use the local release target.
