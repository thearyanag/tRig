import Foundation

struct WalletPortfolioRefresh: Equatable {
  let wallets: [TradingWallet]
  let refreshID: UUID
}

struct WalletPortfolio {
  let snapshots: [WalletHoldingsSnapshot]
  let warnings: [String]

  private var holdings: [PortfolioHolding] {
    let lots = snapshots.flatMap { snapshot in
      snapshot.tokens.map { token in
        let mint = token.address ?? "native:\(snapshot.chain)"
        return PortfolioLot(
          id: Self.key(chain: snapshot.chain, mint: mint) + ":" + snapshot.address,
          chain: snapshot.chain, mint: mint, wallet: snapshot.address,
          name: token.name, symbol: token.symbol, imageUrl: token.imageUrl,
          quantity: token.quantity, priceUsd: token.priceUsd,
          valueUsd: Self.marketValue(token), costBasisUsd: nil, averageEntryUsd: nil,
          pnlPercent: nil, pnlUsd: nil, sources: [.wallet], warnings: [], fetchedAt: snapshot.asOf)
      }
    }
    let marketMints: [String: String] = snapshots.reduce(into: [:]) { map, snapshot in
      for token in snapshot.tokens {
        if let mint = token.marketMint {
          map[Self.key(chain: snapshot.chain, mint: token.address ?? "native:\(snapshot.chain)")] = mint
        }
      }
    }
    return Dictionary(grouping: lots, by: { Self.key(chain: $0.chain, mint: $0.mint) })
      .sorted { $0.key < $1.key }.compactMap { id, lots in
        guard let first = lots.first else { return nil }
        return PortfolioHolding(
          id: id, chain: first.chain, mint: first.mint, marketMint: marketMints[id],
          name: first.name, symbol: first.symbol, imageUrl: first.imageUrl,
          quantity: Self.sum(lots.map(\.quantity)), priceUsd: first.priceUsd,
          valueUsd: Self.sum(lots.map(\.valueUsd), requireAll: true),
          averageEntryUsd: nil, pnlUsd: nil, pnlPercent: nil, sources: [.wallet],
          lots: lots, warnings: [])
      }
  }

  func snapshot(period: PortfolioPeriod) -> PortfolioSnapshot {
    let holdings = holdings
    let knownValue = Self.sum(holdings.flatMap(\.lots).map(\.valueUsd))
    let asOf = snapshots.map(\.asOf).min()
    return PortfolioSnapshot(
      scope: PortfolioScope.wallet.rawValue, period: period,
      totalValueUsd: knownValue ?? (holdings.isEmpty && asOf != nil && warnings.isEmpty ? "0" : nil),
      periodPnlUsd: nil, periodPnlPercent: nil, unrealizedPnlUsd: nil, unrealizedPnlPercent: nil,
      holdings: holdings, history: [], sourceCount: asOf == nil ? 0 : 1,
      asOf: asOf, warnings: Self.notices(warnings, holdings: holdings),
      historyMessage: "Wallet balance history is unavailable.")
  }

  func combined(with connected: PortfolioSnapshot?, scope: String, period: PortfolioPeriod)
    -> PortfolioSnapshot
  {
    let own = snapshot(period: period)
    guard let connected, connected.sourceCount > 0 else {
      return PortfolioSnapshot(
        scope: scope, period: period, totalValueUsd: own.totalValueUsd,
        periodPnlUsd: nil, periodPnlPercent: nil, unrealizedPnlUsd: nil, unrealizedPnlPercent: nil,
        holdings: own.holdings, history: [], sourceCount: own.sourceCount,
        asOf: own.asOf, warnings: (connected?.warnings ?? []) + own.warnings,
        historyMessage: own.historyMessage)
    }
    var rows = Dictionary(uniqueKeysWithValues: connected.holdings.map {
      (Self.key(chain: $0.chain, mint: $0.mint), $0)
    })
    var additionalValues: [String?] = []
    for wallet in own.holdings {
      guard let external = rows[wallet.id] else {
        rows[wallet.id] = wallet
        additionalValues.append(contentsOf: wallet.lots.map(\.valueUsd))
        continue
      }
      let providerAccounts = Set(external.lots.map { Self.accountKey($0.wallet, chain: $0.chain) })
      let distinct = wallet.lots.filter { !providerAccounts.contains(Self.accountKey($0.wallet, chain: $0.chain)) }
      additionalValues.append(contentsOf: distinct.map(\.valueUsd))
      rows[wallet.id] = Self.merge(external, wallet: wallet, newLots: distinct)
    }
    return PortfolioSnapshot(
      scope: scope, period: connected.period,
      totalValueUsd: Self.sum([connected.totalValueUsd] + additionalValues),
      periodPnlUsd: connected.periodPnlUsd, periodPnlPercent: connected.periodPnlPercent,
      unrealizedPnlUsd: connected.unrealizedPnlUsd, unrealizedPnlPercent: connected.unrealizedPnlPercent,
      holdings: rows.values.sorted { $0.id < $1.id }, history: connected.history,
      sourceCount: connected.sourceCount + own.sourceCount,
      asOf: [connected.asOf, own.asOf].compactMap { $0 }.min(),
      warnings: connected.warnings + own.warnings + (own.sourceCount > 0 ? [
        "Wallet holdings contribute to current balances. History and period P&L cover connected platforms."
      ] : []),
      historyMessage: connected.historyMessage)
  }

  private static func merge(_ connected: PortfolioHolding, wallet: PortfolioHolding, newLots: [PortfolioLot])
    -> PortfolioHolding
  {
    PortfolioHolding(
      id: connected.id, chain: connected.chain, mint: connected.mint,
      marketMint: connected.marketMint ?? wallet.marketMint,
      name: connected.name, symbol: connected.symbol, imageUrl: connected.imageUrl ?? wallet.imageUrl,
      quantity: newLots.isEmpty ? connected.quantity
        : sum([connected.quantity] + newLots.map(\.quantity), requireAll: true),
      priceUsd: connected.priceUsd ?? wallet.priceUsd,
      valueUsd: newLots.isEmpty ? connected.valueUsd
        : sum([connected.valueUsd] + newLots.map(\.valueUsd), requireAll: true),
      averageEntryUsd: newLots.isEmpty ? connected.averageEntryUsd : nil,
      pnlUsd: newLots.isEmpty ? connected.pnlUsd : nil,
      pnlPercent: newLots.isEmpty ? connected.pnlPercent : nil,
      sources: connected.sources + [.wallet], lots: connected.lots + newLots,
      warnings: connected.warnings + (newLots.isEmpty ? [] : ["Cost basis is unavailable for the tRig wallet balance."]))
  }

  private static func notices(_ warnings: [String], holdings: [PortfolioHolding]) -> [String] {
    let missingPrice = holdings.contains { $0.valueUsd == nil }
    return warnings + (missingPrice ? ["Some wallet assets have no USD price. Wallet value covers priced assets."] : [])
  }

  private static func marketValue(_ token: WalletHoldingToken) -> String? {
    guard let price = PortfolioFormat.decimal(token.priceUsd),
      let quantity = PortfolioFormat.decimal(token.quantity) else { return nil }
    let value = price * quantity
    return value.isNaN ? nil : NSDecimalNumber(decimal: value).stringValue
  }

  private static func sum(_ values: [String?], requireAll: Bool = false) -> String? {
    let decimals = values.compactMap(PortfolioFormat.decimal)
    guard !decimals.isEmpty, !requireAll || values.count == decimals.count else { return nil }
    let total = decimals.reduce(0, +)
    return total.isNaN ? nil : NSDecimalNumber(decimal: total).stringValue
  }

  private static func key(chain: String, mint: String) -> String {
    "\(chain):\(accountKey(mint, chain: chain))"
  }

  private static func accountKey(_ address: String, chain: String) -> String {
    chain == "solana" ? address : address.lowercased()
  }
}
