import assert from 'node:assert/strict';
import test from 'node:test';
import { codexFailure, hasResearchContext, marketPrompt, researchMessages } from './research-messages.mjs';

const failure = 'exceeded retry limit, last status: 429 Too Many Requests\n\n';

test('separates the unlabelled Codex failure from streamed model text', () => {
  assert.equal(codexFailure('codex', failure), 'Codex rate-limited this request. Try again shortly.');
  assert.equal(codexFailure('codex', failure, 'model-message'), undefined);
  assert.equal(codexFailure('codex', 'Here is a 429 Too Many Requests example.'), undefined);
  assert.equal(codexFailure('grok-build', failure), undefined);
});

test('shows an existing saved Codex failure as a research error', () => {
  const record = { messages: [
    { User: { content: [{ Text: 'How much BP do I have?' }] } },
    { Agent: { content: [{ Text: failure }] } },
  ] };
  assert.deepEqual(researchMessages(record, 'codex'), [
    { role: 'user', text: 'How much BP do I have?' },
    { role: 'error', text: 'Codex rate-limited this request. Try again shortly.' },
  ]);
});

test('grounds each turn in the open market and restores only the original question', () => {
  const question = 'what is BP price atm';
  const prompt = marketPrompt(question, {
    asset: 'solana:BPxxfRCXkUVhig4HS1Lh7kZqV6SPJhzfEk4x6fVBjPCy',
    symbol: 'BP', name: 'Backpack', network: 'Solana',
  });
  assert.ok(prompt.includes('"name":"Backpack","network":"Solana"'));
  assert.match(prompt, /get_market_overview tool with no arguments first/);
  assert.ok(hasResearchContext(prompt));
  const previous = 'old question\n\n--- tRig attachments ---\nold context';
  assert.deepEqual(researchMessages({ messages: [previous, prompt].map(Text => ({ User: { content: [{ Text }] } })) }, 'codex'), [
    { role: 'user', text: 'old question' },
    { role: 'user', text: question },
  ]);
});
