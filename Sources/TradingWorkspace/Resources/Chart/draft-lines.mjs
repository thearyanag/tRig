const keys = ['limit', 'take-profit', 'stop-loss'];

function appearance(draft) {
  const color = draft.id === 'stop-loss' ? '#ff9f43'
    : draft.id === 'take-profit' || draft.side === 'buy' ? '#24d49e' : '#db2e42';
  const label = draft.id === 'take-profit' ? 'TP'
    : draft.id === 'stop-loss' ? 'SL' : `${draft.side} limit`;
  return {
    style: { lineColor: color, lineWidth: 2, lineStyle: 'dashed' },
    text: {
      value: `Draft ${label} · not placed`, color, size: 'small', hAlign: 'left', vAlign: 'top',
    },
  };
}

// Native drafts own price and revision. Vela's drawing is the interactive projection.
export function createDraftLinesController(chart, mint, post) {
  const entries = new Map();
  const owned = new Set();
  const removedRevisions = new Map();
  let applying = false;
  let disposed = false;
  let reconcileQueued = false;

  function apply() {
    if (disposed || applying) return;
    applying = true;
    try {
      const drawings = new Map(chart.drawings.all().map(drawing => [drawing.id, drawing]));
      const active = new Set();
      for (const entry of entries.values()) {
        const current = drawings.get(entry.drawingID);
        const range = chart.getVisibleRange();
        const time = current?.anchors[0]?.time ?? (range ? (range.from + range.to) / 2 : Date.now());
        const anchor = { time, price: entry.draft.price };
        const look = appearance(entry.draft);
        if (!current) {
          const drawing = chart.drawings.add('hline', {
            anchors: [anchor], ...look,
          });
          entry.drawingID = drawing?.id;
          if (drawing) owned.add(drawing.id);
        } else if (current.anchors[0]?.price !== anchor.price
            || current.text?.value !== look.text.value || current.style.lineColor !== look.style.lineColor) {
          chart.drawings.update(current.id, { anchors: [anchor], ...look });
        }
        active.add(entry.drawingID);
      }
      for (const id of drawings.keys()) {
        if (owned.has(id) && !active.has(id)) chart.drawings.remove(id);
      }
    } finally {
      applying = false;
    }
  }

  function reconcileAfterHistory() {
    if (applying || disposed || reconcileQueued) return;
    reconcileQueued = true;
    // Vela restores drawings on undo/redo before announcing its reconciled selection.
    queueMicrotask(() => {
      reconcileQueued = false;
      apply();
    });
  }

  function changed(id, removed) {
    if (applying || disposed) return;
    for (const [key, entry] of entries) {
      if (entry.drawingID !== id) continue;
      const draft = entry.draft;
      const identity = { id: key, mint, revision: draft.revision };
      if (removed) {
        removedRevisions.set(key, draft.revision);
        entries.delete(key);
        post({ ...identity, removed: true });
      } else {
        // The edit event fires after Vela commits the gesture to its drawing model.
        const price = chart.drawings.all().find(drawing => drawing.id === id)?.anchors[0]?.price;
        if (Number.isFinite(price) && price > 0 && price !== draft.price) {
          entry.draft = { ...draft, price };
          post({ ...identity, price });
        }
      }
      return;
    }
  }

  const unsubscribe = [
    chart.on('drawing:edited', ({ id }) => changed(id, false)),
    chart.on('drawing:removed', ({ id }) => changed(id, true)),
    chart.on('drawing:selected', reconcileAfterHistory),
  ];

  return {
    set(values) {
      if (disposed) return;
      const lines = Array.isArray(values) ? values : [];
      for (const key of keys) {
        const next = lines.find(line => line?.id === key && line.mint === mint
          && typeof line.revision === 'string' && ['buy', 'sell'].includes(line.side)
          && Number.isFinite(line.price) && line.price > 0);
        const current = entries.get(key);
        if (!next || removedRevisions.get(key) === next.revision) {
          entries.delete(key);
        } else if (current?.draft.revision !== next.revision || current.draft.side !== next.side) {
          // An echo with the original revision acknowledges a drag. Only a native edit moves it.
          entries.set(key, {
            draft: { ...next }, drawingID: current?.drawingID,
          });
        }
      }
      apply();
    },
    dispose() {
      for (const stop of unsubscribe) stop();
      entries.clear();
      apply();
      disposed = true;
    },
  };
}
