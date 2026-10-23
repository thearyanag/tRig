export type Bar = { time: number; open: number; high: number; low: number; close: number; volume: number };
export const intervals = { '15': 900, '60': 3600, '1D': 86400 } as const;
export type Interval = keyof typeof intervals;
export const products = ['SOL-USD', 'BTC-USD', 'ETH-USD'] as const;
export type Product = typeof products[number];
export type Snapshot = { bars: Bar[]; product: Product; interval: Interval; source: string; capturedAt: string };

export function normalizeCoinbase(rows: unknown): Bar[] {
  if (!Array.isArray(rows) || rows.length === 0) throw new Error('The market feed returned no candles.');
  const bars = new Map<number, Bar>();
  for (const row of rows) {
    if (!Array.isArray(row) || row.length < 6 || !row.slice(0, 6).every(Number.isFinite)) throw new Error('Invalid candle from the market feed.');
    const [time, low, high, open, close, volume] = row;
    if (time <= 0 || !Number.isInteger(time) || low <= 0 || low > Math.min(open, close) || high < Math.max(open, close) || volume < 0) throw new Error('Invalid OHLCV values.');
    bars.set(time, { time: time * 1000, open, high, low, close, volume });
  }
  return [...bars.values()].sort((a, b) => a.time - b.time);
}

/** Deterministic fixture. Never represented as historical market prices. */
export function syntheticSnapshot(product: Product, interval: Interval, count = 10000): Snapshot {
  let seed = 4137;
  const random = () => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed / 4294967296; };
  const step = intervals[interval] * 1000;
  const end = Date.UTC(2026, 9, 22);
  let close = { 'SOL-USD': 150, 'BTC-USD': 90000, 'ETH-USD': 3000 }[product];
  const bars = Array.from({ length: count }, (_, i) => {
    const open = close;
    close = Math.max(0.001, open * (1 + (random() - 0.5) * 0.018 + Math.sin(i / 41) * 0.001));
    return { time: end - (count - i - 1) * step, open, close,
      high: Math.max(open, close) * (1 + random() * 0.009),
      low: Math.min(open, close) * (1 - random() * 0.009), volume: Math.round(100 + random() * 10000) };
  });
  return { bars, product, interval, source: 'Synthetic stress fixture', capturedAt: new Date(end).toISOString() };
}

export function historyPage(bars: Bar[], toMs: number, count: number): Bar[] {
  return bars.filter(bar => bar.time < toMs).slice(-Math.max(1, count)).map(bar => ({ ...bar }));
}

/** Copies at every engine boundary: either engine may mutate its own bars. */
export class SharedTape {
  private listeners = new Set<(bar: Bar) => void>();
  readonly snapshot: Snapshot;
  cursor: number;
  constructor(snapshot: Snapshot, cursor = snapshot.bars.length) {
    this.snapshot = snapshot;
    this.cursor = Math.min(snapshot.bars.length, Math.max(1, cursor));
  }
  get bars() { return this.snapshot.bars.slice(0, this.cursor).map(bar => ({ ...bar })); }
  subscribe(callback: (bar: Bar) => void) { this.listeners.add(callback); return () => this.listeners.delete(callback); }
  step() {
    if (this.cursor >= this.snapshot.bars.length) return false;
    const bar = this.snapshot.bars[this.cursor++];
    for (const listener of this.listeners) listener({ ...bar });
    return true;
  }
  dispose() { this.listeners.clear(); }
}

export async function fingerprint(bars: Bar[]) {
  const bytes = new TextEncoder().encode(JSON.stringify(bars));
  const hash = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(hash)].map(b => b.toString(16).padStart(2, '0')).join('').slice(0, 12);
}
