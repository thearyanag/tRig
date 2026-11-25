const contextMarker = '\n\n--- tRig attachments ---\n';
const marketMarker = '\n\n--- tRig active market ---\n';

export function hasResearchContext(question) {
  return question.includes(contextMarker) || question.includes(marketMarker);
}

export function marketPrompt(question, { asset, symbol, name, network }) {
  return question + marketMarker + JSON.stringify({ asset, symbol, name, network }) +
    '\nThe market above is open in tRig for this turn. Use it for references to the current asset or its ticker, unless the user refers to a different asset. ' +
    'For the open market’s current price or market statistics, call the tRig get_market_overview tool with no arguments first. ' +
    'If it cannot return the requested data, report that for this market. Use the tRig tools to fetch financial and discussion data as needed.';
}

const codexRateLimit = /^exceeded retry limit, last status: 429 too many requests$/i;
const rateLimitNotice = 'Codex rate-limited this request. Try again shortly.';

// The Codex ACP adapter sends this failure as an unlabelled agent message.
export function codexFailure(provider, text, messageId) {
  if (provider === 'codex' && !messageId && codexRateLimit.test(text.trim())) return rateLimitNotice;
}

export function researchMessages(record, provider) {
  return (record?.messages ?? []).flatMap(message => {
    const role = message.User ? 'user' : message.Agent ? 'assistant' : null;
    if (!role) return [];
    let text = (message.User ?? message.Agent).content.map(item => item.Text ?? '').join('');
    if (role === 'user') text = text.split(contextMarker)[0].split(marketMarker)[0];
    if (!text.trim()) return [];
    const failure = role === 'assistant' && codexFailure(provider, text);
    return failure ? [{ role: 'error', text: failure }] : [{ role, text }];
  });
}
