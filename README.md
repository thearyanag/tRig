# tRig

**From discovery to an informed thesis.**

*tRig = trading rig.*

An open-source crypto workbench for pro traders. Connect your conversations, social trading accounts, market data, and supported AI subscriptions in one workspace.

## Why tRig

Discovering an asset takes seconds. Understanding whether it deserves your attention takes much longer.

Relevant information is scattered across conversations, social posts, market data, and wallet activity. Traders spend time finding sources, reconstructing context, and checking claims before they can form a view.

**tRig shortens that path.** It brings those sources into a shared workspace, with an assistant that helps connect evidence, surface disagreements, and identify what’s still unknown.

The goal is to help traders reach a thesis they can explain, challenge, and revisit as new information arrives.

## What we’re building

### Connect the platforms you already use

Keep your existing accounts, communities, and audiences. Bring them into tRig, starting with:

- **Telegram** — conversations and communities.
- **Pump** — profiles, callouts, and social trading activity.
- **Fomo** — profiles, theses, and trading context.

Additional market-data sources, wallets, and exchanges will expand the workbench.

### Bring your AI

Connect supported AI subscriptions and choose the model you want to work with.

The first integration uses **Sign in with ChatGPT** and eligible ChatGPT plan usage. Additional providers will be added through their supported integration paths.

The assistant will work across connected platforms, carrying the context of your research with it. You control what information it receives and which actions it can take.

### Build a view from evidence

Organize research around an asset, wallet, trader, or thesis.

- Gather relevant discussions and supporting data.
- Compare competing arguments.
- Trace claims back to their sources.
- Identify missing evidence and unanswered questions.
- Save your conclusions and revisit them as conditions change.

### Move from research to action

Draft a callout, publish a thesis, or share a finding from the same workspace.

Actions should make the account, destination, and outcome clear. Trading and wallet execution are future integration areas.

## A workflow

1. Open an asset mentioned in a conversation.
2. Gather relevant callouts, theses, market data, and wallet activity.
3. Ask the assistant to compare the arguments and identify gaps in the evidence.
4. Form and save your own thesis.
5. Review and publish it to a connected platform.
6. Revisit it as new information arrives.

## Principles

- **Use existing networks.** Connect the platforms where traders already participate.
- **Keep context connected.** Research should remain useful across sources, platforms, and models.
- **Show the evidence.** Preserve source links and timestamps. Distinguish facts, opinions, and inference.
- **Keep the trader in control.** Make context sharing and consequential actions explicit.
- **Build in the open.** Keep the application and integration code inspectable and extensible.

## Development status

The macOS prototype includes:

- A native workbench with asset search, a persistent watchlist, and a shared asset selection.
- Bundled Vela charts backed by a local Rust market-data service.
- Read-only Pump and Fomo portfolios backed by separate local website sessions.
- Read-only Telegram discussion tied to the contract currently open in Markets.
- Market, limit, and TP/SL quote previews.

Pump and Fomo integrations use website endpoints, which can change. The research assistant and order execution are planned.

## Run the macOS prototype

Requires macOS 14 or later, Xcode 26 / Swift 6.2, Rust/Cargo, and Node.js 22.12+ with npm. Vela is bundled during the build. No third-party Swift packages, proprietary chart library or API key are needed.

```sh
swift test
cargo test --manifest-path backend/trading-data/Cargo.toml --locked
node --test Tests/ChartHost/*.test.cjs Tests/ConnectionHost/*.test.cjs
./script/build_and_run.sh
```

The script assembles and launches `dist/TradingWorkspace.app`. Use **Settings** to connect accounts. See the [macOS development guide](docs/trading-workspace.md) and [Telegram setup](docs/telegram-discussion.md) for configuration.

## Local app, explicit connections

Account sessions and credentials are managed locally. Connected services receive the requests needed to operate their integrations.

Using a cloud model sends your prompts and explicitly attached context to that provider. Running tRig locally does not mean model inference runs locally.

## Contributing

Early contributions are welcome around:

- Pro-trader workflows and product feedback.
- Platform and market-data connectors.
- Model-provider integrations.
- The native macOS experience.
- Reliability, testing, and security review.

Start with the macOS development guide. More detailed contribution guidelines will follow as the shared architecture takes shape.
