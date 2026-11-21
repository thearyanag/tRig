(() => {
  "use strict";
  // Advanced Charts drawing, never a broker order or an execution primitive.
  window.createDraftLimitController = (widget, mint, digits, post, key = "limit") => {
    let desired = null;
    let lineId = null;
    let creating = false;
    let disposed = false;
    let updating = false;
    let pointerDown = false;
    let pendingNative = null;
    let appliedSide = null;
    let moveQueued = false;
    const ownedIds = new Set();
    const chart = widget.activeChart();
    const valid = value => value && (value.id ?? "limit") === key && value.mint === mint && typeof value.revision === "string"
      && ["buy", "sell"].includes(value.side) && Number.isFinite(value.price) && value.price > 0;
    const samePrice = (a, b) => Math.abs(a - b) < Math.max(10 ** -digits / 2, Math.abs(b) * 1e-12);
    const text = value => key === "take-profit" ? "Draft TP · not placed"
      : key === "stop-loss" ? "Draft SL · not placed" : `Draft ${value.side} limit · not placed`;
    const color = value => key === "take-profit" ? "#24d49e" : key === "stop-loss" ? "#ff9f43"
      : value.side === "buy" ? "#24d49e" : "#db2e42";
    const properties = value => ({
      linecolor: color(value),
      textcolor: color(value),
      linewidth: 2, linestyle: 2, showPrice: true, showLabel: true,
      fontsize: 12, bold: true, horzLabelsAlign: "right", vertLabelsAlign: "top",
      text: text(value)
    });
    function remove() {
      const id = lineId;
      lineId = null;
      if (id !== null) chart.removeEntity(id, { disableUndo: true });
    }
    async function render() {
      if (disposed) return;
      if (!desired) { remove(); return; }
      // TradingView owns the drawing geometry until the pointer is released.
      if (pointerDown || moveQueued) return;
      if (lineId !== null) {
        try {
          const shape = chart.getShapeById(lineId);
          updating = true;
          const point = shape.getPoints()[0];
          if (!point || !samePrice(point.price, desired.price)) {
            shape.setPoints([{ time: point?.time ?? Math.floor(Date.now() / 1000), price: desired.price }]);
          }
          if (appliedSide !== desired.side) {
            shape.setProperties(properties(desired));
            appliedSide = desired.side;
          }
          updating = false;
          return;
        } catch (_) { updating = false; lineId = null; }
      }
      if (creating || !chart.dataReady()) return;
      creating = true;
      const requested = desired;
      try {
        const id = await chart.createShape({ time: Math.floor(Date.now() / 1000), price: requested.price }, {
          shape: "horizontal_line", text: text(requested),
          lock: false, disableSelection: false, disableSave: true, disableUndo: true,
          showInObjectsTree: false, zOrder: "top", overrides: properties(requested)
        });
        ownedIds.add(id);
        if (disposed || desired !== requested) chart.removeEntity(id, { disableUndo: true });
        else { lineId = id; appliedSide = requested.side; }
      } catch (_) {
        // Candle loading/interval changes can briefly make drawings unavailable.
        // Retried when data loads or the user changes the numeric target.
      } finally {
        creating = false;
        if (!disposed && desired !== requested) void render();
      }
    }
    function mouseDown() { pointerDown = true; }
    function flushNative() {
      if (!pointerDown && pendingNative) {
        desired = pendingNative;
        pendingNative = null;
        void render();
      }
    }
    function mouseUp() {
      // The library emits mouse_up before finishing its internal move cleanup.
      // Apply external commands only after that event stack has completed.
      queueMicrotask(() => {
        pointerDown = false;
        if (!moveQueued) flushNative();
      });
    }
    function drawingEvent(id, event) {
      if (!disposed && ownedIds.has(id) && id !== lineId && event === "create") {
        chart.removeEntity(id, { disableUndo: true });
        return;
      }
      if (disposed || updating || id !== lineId || !desired) return;
      if (event === "remove") {
        const previous = desired;
        lineId = null;
        desired = null;
        post({ id: key, mint, revision: previous.revision, removed: true });
      } else if (event === "move" || event === "points_changed") {
        if (moveQueued) return;
        moveQueued = true;
        const revision = desired.revision;
        // During move/endChanging, getPoints() includes TradingView's temporary
        // drag offset. Read only after its event stack has cleared that offset;
        // otherwise it gets applied twice when synchronized back to the ticket.
        queueMicrotask(() => {
          moveQueued = false;
          if (disposed || lineId !== id || !desired || desired.revision !== revision) return;
          const price = chart.getShapeById(id).getPoints()[0]?.price;
          if (Number.isFinite(price) && price > 0 && !samePrice(price, desired.price)) {
            desired = { ...desired, price };
            post({ id: key, mint, revision, price });
          }
          flushNative();
        });
      }
    }
    // TradingView can restore deleted drawings through Undo. Native state remains
    // authoritative: an old draft must never reappear detached from its ticket.
    function removeOrphans() {
      if (disposed || creating) return;
      for (const shape of chart.getAllShapes()) {
        if (ownedIds.has(shape.id) && shape.id !== lineId) {
          chart.removeEntity(shape.id, { disableUndo: true });
        }
      }
    }
    widget.subscribe("drawing_event", drawingEvent);
    widget.subscribe("undo_redo_state_changed", removeOrphans);
    widget.subscribe("mouse_down", mouseDown);
    widget.subscribe("mouse_up", mouseUp);
    const dataLoaded = () => void render();
    chart.onDataLoaded().subscribe(null, dataLoaded);
    return {
      set(value) {
        if (!valid(value)) {
          desired = null;
          pendingNative = null;
          void render();
          return;
        }
        // The same native revision is an acknowledgement of chart-originated
        // movement, possibly delayed by several frames. Never move the line back
        // to that older price or reset its properties during the drag.
        if (desired && value.revision === desired.revision && value.side === desired.side) return;
        if (pointerDown) { pendingNative = { ...value }; return; }
        desired = { ...value };
        void render();
      },
      dispose() {
        disposed = true;
        desired = null;
        pendingNative = null;
        widget.unsubscribe("drawing_event", drawingEvent);
        widget.unsubscribe("undo_redo_state_changed", removeOrphans);
        widget.unsubscribe("mouse_down", mouseDown);
        widget.unsubscribe("mouse_up", mouseUp);
        chart.onDataLoaded().unsubscribe(null, dataLoaded);
        remove();
      }
    };
  };

  // Stable controllers keep each line's gesture/revision independent. Updating
  // one exit must never reposition, recreate, or clear its sibling.
  window.createDraftLinesController = (widget, mint, digits, post) => {
    const controllers = new Map(["limit", "take-profit", "stop-loss"].map(key => [
      key, window.createDraftLimitController(widget, mint, digits, post, key)
    ]));
    return {
      set(values) {
        const lines = Array.isArray(values) ? values : [];
        for (const [key, controller] of controllers) {
          controller.set(lines.find(line => line?.id === key) ?? null);
        }
      },
      dispose() { for (const controller of controllers.values()) controller.dispose(); }
    };
  };
})();
