# Telegram discussion in Markets

Connect Telegram in Settings, then open an asset and choose Context. tRig shows
text quotes in the groups and direct messages where Telegram found the selected
contract. Forum topics stay nested under their group and use titles returned by
Telegram. The asset header's Telegram discussion button opens the sidebar.

## Local setup

1. Build the optional Telegram library with `./script/build_tdlib.sh`.
   It needs Xcode command-line tools, CMake, Ninja, gperf, and Perl. The script
   builds pinned official TDLib and OpenSSL from source for the host architecture
   with a macOS 14 deployment target. It places the binary and license notices
   under the ignored `.build/telegram/` directory.
2. Register the app at [Telegram API development tools](https://my.telegram.org).
   Put the developer credentials in a file named `telegram.json` under
   `~/Library/Application Support/com.aryan.TradingWorkspace/`. Keep the file
   private and out of Git. The shape is:

   ```json
   { "api_id": 12345, "api_hash": "<32 hex characters>" }
   ```

3. Run `./script/build_and_run.sh`. It bundles TDLib when the local library
   build is available. Settings shows the missing configuration or library
   state when either dependency is unavailable.
4. Connect with a QR code from an existing Telegram session or use phone sign-in.
   Enter any requested verification codes and two-step verification in the app.
   The app owns a separate local Telegram authorization. Its encrypted TDLib
   database key lives in the Mac Keychain. Disconnect logs out of that
   authorization and removes its local data after TDLib closes.

## Search and provenance

The Mac app sends the selected contract to Telegram's own message search when the
Context panel opens or refreshes. Older results can be requested explicitly.
tRig keeps result previews in memory and does not upload them to the Rust service.
The pinned TDLib interface is used for authentication, search and source lookup.

Each exact contract match starts a separate exchange. tRig shows the original
share, its parent when the share replied to an earlier message, and a bounded
set of direct replies from the same chat and topic. When a filtered reply quotes
an eligible parent that shared the same contract, tRig uses the parent as the
exchange instead of showing a duplicate. Opening a chat or topic
shows these exchanges directly. The selected contract is
displayed as a token icon and cashtag, including when it was the entire message.
For EVM, an address without a link to the selected chain's explorer is labeled
“Chain unconfirmed.”

For a share with no prose, the sidebar previews the closest eligible text
message before and after it when available. **Show surrounding messages**
loads up to three eligible messages before and
after the share. These are labeled separately from replies. In groups with
topics, this uses Telegram's forum topic history and verifies the topic again
in the response. Search and context are bounded by Telegram's index and
pagination and do not cover the entire archive.

The sidebar shows discussions from groups and DMs with people. It hides bot DMs
in both directions and excludes posts sent by bots in groups, while keeping
relevant replies written by people. Broadcast channels, Secret Chats, protected
or disappearing content, and attachment downloads are outside this build.
Message links appear for supported supergroups and are requested on click.
There is no send, reply, or mark-as-read request in the transport interface.

See [Telegram's client API terms](https://core.telegram.org/api/terms) for
distribution and content requirements.
