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

The first macOS prototype is in [`apps/macos`](apps/macos). It includes:

- A native workbench with asset search, a persistent watchlist, and a shared asset selection.
- Bundled Vela charts backed by a local Rust market-data service.
- Separate, persistent Pump and Fomo website sessions.
- Native profile and social-content reads.
- Reviewed callout and thesis publishing to Pump and Fomo.
- A ChatGPT-connected assistant with streaming responses, optional post attachments, and draft handoff.

These flows have been exercised locally. They are an early prototype, not the complete workbench described above. Pump and Fomo integrations currently use their website endpoints, which can change.

Telegram connectivity has been prototyped separately through TDLib and is not included in this initial code drop. The next step is bringing the integrations into a shared workspace with a common connector and assistant-tool architecture.

## Run the macOS prototype

Requires macOS 14 or later, Xcode 26 / Swift 6.2, Rust/Cargo, and Node.js 22.12+ with npm. Vela is bundled during the build. No third-party Swift packages, proprietary chart library or API key are needed.

```sh
cd apps/macos
swift test
cargo test --manifest-path backend/trading-data/Cargo.toml --locked
node --test Tests/ChartHost/chart-datafeed.test.cjs
./script/build_and_run.sh
```

The script builds and locally signs `dist/tRig.app`. Sign in to Pump or Fomo through the app’s website view. Use **Continue with ChatGPT** in the assistant sidebar to connect an eligible ChatGPT plan.

See the [macOS development guide](apps/macos/README.md) for setup, architecture, and current limitations.

## Compare chart engines locally

[`apps/chart-compare`](apps/chart-compare) is a small browser experiment comparing Vela with TradingView Advanced Charts on shared candle snapshots. It includes replay, a 10,000-bar synthetic fixture, and independent indicator and drawing tools.

```sh
cd apps/chart-compare
npm ci
npm run dev
```

Open `http://127.0.0.1:5174`. The comparison’s TradingView pane requires a separately installed authorized local library; the macOS app uses bundled Vela. See the [comparison guide](apps/chart-compare/README.md) for setup and test boundaries.

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
