# tRig macOS disk image

Run `./script/build_tdlib.sh` once for the host architecture. From a machine
with Python 3 and the app's build tools, run `./script/package_dmg.sh` after
setting up the release Telegram credentials below. The packager builds the Swift
app and Rust helper and assembles a fresh bundle. It leaves the running
development app alone.

## Telegram release configuration

Register tRig through [Telegram API development tools](https://my.telegram.org).
Store the dedicated app credentials in a private file outside the repository at
`~/Library/Application Support/com.aryan.TradingWorkspace/telegram-release.json`,
or set `TRIG_TELEGRAM_RELEASE_CONFIG` to the absolute path of a private file
supplied by the release environment. The file uses these fields:

```json
{ "api_id": 12345, "api_hash": "<32 hex characters>" }
```

The release build validates the file and compiles the two fields into the
executable before signing. A fresh install can open **Settings → Connect Telegram**
and sign in via QR or phone. Treat the compiled credentials as extractable and
keep their source file private. Telegram user sessions and database keys are
created on the receiving Mac. A release uses a separate session from the
development build and retains it across releases that use the same app ID.

## Signing and review image

The packager signs the helper and TDLib before signing the app with Developer ID,
a secure timestamp, and Hardened Runtime. If the keychain has multiple eligible
identities, set `TRIG_DEVELOPER_ID` to the chosen identity. The script creates
`dist/tRig-<version>-mac-<arch>-review.dmg`, verifies the signature, and checks
that the disk image mounts with the app and an Applications shortcut.

The image targets macOS 14 or later. The local arm64 build is for Apple silicon.
Provider configuration, account sessions, and local databases stay outside the
bundle in Application Support.

## Portfolio Pulse

Open **Edit Widgets** on the desktop or in Notification Center and add the
medium **Portfolio Pulse** widget from Trading Workspace. Click the widget
to open Portfolio. It displays the latest snapshot saved by the app.

The signed app and its sandboxed WidgetKit extension share an App Group
derived from the signing certificate's Team ID. The group holds only the
widget summary. The app handles provider refresh and account sessions. Today's
move is the balance change across comparable portfolio history since local
midnight. Top unrealized uses the holding with the largest absolute unrealized
P&L. Missing or incomparable history shows an unavailable state.

For local widget verification, set `TRIG_WIDGET_SIGN_IDENTITY` to a Developer ID
Application identity before running `./script/build_and_run.sh --verify`.

A review image is signed but has no Apple notarization ticket. Before sending a
release to testers, confirm permission to redistribute any bundled vendor code,
then submit the signed disk image to Apple's notary service. After acceptance,
staple and validate the ticket and verify Gatekeeper on a clean Mac. Use the
stapled file for the handoff.
