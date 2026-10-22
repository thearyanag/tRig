# tRig for macOS

An early SwiftUI workbench connecting Pump, Fomo, and ChatGPT. It combines persistent website sign-in with native profile reads, social-content tools, and an assistant sidebar.

## Requirements

- macOS 14 or later.
- Xcode 26 / Swift 6.2 selected as the active developer toolchain.
- Existing Pump/Fomo accounts for authenticated integration testing.
- An eligible ChatGPT account granting plan usage to test the assistant.

No third-party Swift packages are required. Automated tests use synthetic fixtures and do not log in, publish posts, or place trades.

## Build and run

From this directory:

```sh
swift test
./script/build_and_run.sh
```

Additional modes:

```sh
./script/build_and_run.sh --build-only
./script/build_and_run.sh --verify
```

`--build-only` creates `dist/tRig.app` without stopping or launching an app. The normal run mode stops the existing prototype process, builds, signs the bundle ad hoc, and launches it. `--verify` also checks that the process started. Ad-hoc signing is for local development, not a notarized distribution build.

The Swift executable/module remains `AccountWebTest` and the bundle identifier remains `local.telemo.AccountWebTest` temporarily. Keeping these identifiers preserves existing prototype website sessions and ChatGPT registrations. New installs use the same isolated storage layout; credentials are never included in the repository. A future identity migration should explicitly migrate storage before changing these identifiers.

## Using the prototype

1. Select Pump or Fomo and sign in through the official website view. Each service has a separate persistent WebKit data store.
2. Open **Native tools**. For Pump, refresh the profile and enter a callout link or Solana coin address. For Fomo, enter your own profile handle, load its trades, or read a token’s theses.
3. To publish, enter text and select the target coin/trade. Review the account, destination, and exact text before using the publish button. These actions create real public posts.
4. Open **Assistant**, choose **Continue with ChatGPT**, and finish authorization in the system browser. The model picker is populated from the connected account.
5. Ask a question, or explicitly attach posts already loaded in the native tools. **Use as draft** copies a completed answer to the composer for review; it does not publish it.

The Fomo composer currently supports text theses on existing Solana trades from the requested profile. Verify that this profile matches the account signed in on the website. A profile lookup does not independently establish session ownership. The server authorizes the session; successful post verification checks the returned author, ID, and exact text.

The Pump composer checks posting eligibility and verifies its current session account. Both composers block automatic retries and remember attempted drafts locally to reduce accidental duplicate publication. An ambiguous submission must be checked on the platform before another attempt.

## Source layout

| File | Responsibility |
| --- | --- |
| `Sources/AccountWebTest/AccountWebTest.swift` | App shell, separate WebKit sessions, navigation and login popups |
| `Sources/AccountWebTest/PumpProfile.swift` | Pump session-scoped native profile reads |
| `Sources/AccountWebTest/PumpCallouts.swift` | Callout reads, eligibility checks, reviewed publishing and read-back |
| `Sources/AccountWebTest/FomoNative.swift` | Fomo profile/trade/thesis reads, reviewed publishing and rate-limit hints |
| `Sources/AccountWebTest/ChatGPTOAuth.swift` | Loopback callback, PKCE, state validation and RSA ID-token verification |
| `Sources/AccountWebTest/ChatGPTAccount.swift` | Protected account storage, model discovery, token refresh and streamed inference |
| `Sources/AccountWebTest/ChatGPTSidebar.swift` | Separate conversations, explicit context attachments and draft handoff |
| `Tests/AccountWebTestTests` | Credential scope, input validation, OAuth and streaming tests |

## Sessions and credentials

- Pump and Fomo sessions live in separate persistent `WKWebsiteDataStore` instances within the app’s sandbox. Safari and Chrome profiles are not read.
- Native requests forward only the selected service’s scoped credentials to fixed API hosts. They do not forward Google cookies or service refresh tokens. Redirects are disabled for these native requests.
- ChatGPT uses the documented [personal-local/OSS sign-in flow](https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt). It does not read credentials from Codex or another app.
- ChatGPT credentials are stored under the app container’s `Application Support/AccountWebTest/ChatGPT` directory, with directory mode `0700`, file mode `0600`, and atomic writes. Tokens are not logged or attached to model prompts.
- The app is sandboxed with outbound networking and an inbound-network entitlement for its short-lived OAuth listener. That listener binds only to `127.0.0.1`.
- Chat requests use the public Responses API with `store: false` and `stream: true`. A response is complete only after `response.completed`.
- Conversations stay in memory. Attached posts remain in their conversation until it is cleared. The assistant receives no account balances, cookies, or keys through the attachment feature and has no execution tools.

## Validation and limitations

Locally exercised flows include both service logins, restart persistence, native profile/social reads, reviewed public posts, and completed ChatGPT inference. The automated suite checks the relevant request boundaries and uses synthetic identities; it is not an end-to-end production API test.

Current limits:

- Website endpoints are undocumented integration surfaces and may change. This app is not an official Pump or Fomo client.
- Pump/Fomo expiry-triggered session renewal is not independently implemented. Their website views manage their own sessions.
- ChatGPT refresh handling is implemented, but live expiry-triggered refresh has not been verified.
- Passkeys for third-party websites are limited by the hosting app’s WebKit entitlement/domain requirements.
- Reads cover bounded pages, not complete histories. There is no shared research database, autonomous monitoring, or trading/signing integration yet.
- Fomo’s sampled read responses did not expose rate-limit headers. The panel displays headers when supplied and honors `Retry-After`; quotas have not been stress-tested.
- The Fomo composer’s 1,000-character ceiling is a local prototype limit, not a claim about the platform’s maximum.

Review [OpenAI’s current integration eligibility](https://developers.openai.com/siwc/token-sharing-open-source) before changing the distribution model. A working personal-local prototype does not establish eligibility for paid or remotely hosted distribution.
