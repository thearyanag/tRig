# Optional comparison dependency

The macOS app now bundles Vela and does not load this directory.

The separate `apps/chart-compare` experiment can still serve an authorized TradingView Advanced Charts `charting_library/` placed here, or supplied through `TRIG_TRADINGVIEW_LIBRARY_PATH`.

The proprietary library remains ignored. Do not commit it. See the [comparison guide](../../../chart-compare/README.md).
