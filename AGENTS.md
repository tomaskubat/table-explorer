# Project essentials

TableExplorer is a native macOS app using SwiftUI and AppKit. See [README.md](README.md) for build, signing verification, and release instructions.

## Builds and signing

- Use `make build` or `make run` for local testing. These build the app and verify its signature.
- Local builds and releases must use the existing `TableExplorer Local Code Signing` certificate. Ad-hoc signing changes the app's identity between builds and causes repeated Keychain access prompts.
- [Configuration/CodeSigning.xcconfig](Configuration/CodeSigning.xcconfig) selects the identity. [Configuration/table-explorer-signing.pem](Configuration/table-explorer-signing.pem) is its public certificate. Keep them consistent; use [Scripts/app-signature.sh](Scripts/app-signature.sh) to verify signing.
- The private key stays in the signing Mac's Keychain. Use the existing identity rather than generating a replacement to fix a build failure. Installing releases on other Macs requires no private key.
- Preserve the bundle identifier `local.connectionbrowser.app` and the Keychain services `local.connectionbrowser.database` and `local.connectionbrowser.ssh`. These legacy names maintain access to existing credentials despite the TableExplorer product name.
- Sparkle update signing uses a separate key. The local code signing certificate does not provide Developer ID notarization.

## Testing with user data

- Use disposable SQLite databases and set `CONNECTION_BROWSER_LIBRARY` to an absolute temporary directory for isolated connection profiles. Saved user connections may point to production databases.
- [Scripts/check-workspace-feedback.sh](Scripts/check-workspace-feedback.sh) exercises the native workspace against private fixtures.
- Before restarting the app for manual testing, account for unsaved edits in any running instance.
