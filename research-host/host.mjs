import { createServer } from 'node:http';
import { accessSync, constants, statSync } from 'node:fs';
import { mkdir, readdir, readFile, rename, writeFile } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { homedir } from 'node:os';
import { dirname, isAbsolute, join } from 'node:path';
import { promisify } from 'node:util';
import { once } from 'node:events';
import { createAcpRuntime, createRuntimeStore, inspectAgentModels } from 'acpx/runtime';
import { codexFailure, hasResearchContext, marketPrompt, researchMessages } from './research-messages.mjs';
import { createResearchTools, researchTools } from './research-tools.mjs';

const [socket, state] = process.argv.slice(2);
const dataUrl = process.env.TRIG_RESEARCH_DATA_URL;
delete process.env.TRIG_RESEARCH_DATA_URL;
if (!isAbsolute(socket ?? '') || !isAbsolute(state ?? '') || !dataUrl) process.exit(1);
process.umask(0o077);
for (const name of Object.keys(process.env)) {
  if (name.startsWith('ACPX_AUTH_') || /^(ANTHROPIC_API_KEY|OPENAI_API_KEY|CODEX_API_KEY|CODEX_ACCESS_TOKEN|XAI_API_KEY|GROK_API_KEY|GEMINI_API_KEY|GOOGLE_.*)$/.test(name)) {
    delete process.env[name];
  }
}

const work = join(state, 'workspace');
await mkdir(work, { recursive: true });
const store = createRuntimeStore({ stateDir: join(state, 'sessions') });
const exec = promisify(execFile);
const providers = {
  codex: { executable: 'codex', args: [] },
  'grok-build': { executable: 'grok', args: ['agent', 'stdio'] },
  antigravity: { executable: 'agy', args: ['acp', '--process-per-session', '--sandbox', '--disable-telemetry', '--include-default-customizations=false'] },
};
const searchPaths = Array.from(new Set([
  join(homedir(), '.local', 'bin'), '/opt/homebrew/bin', '/usr/local/bin', dirname(process.execPath),
  ...(process.env.PATH ?? '').split(':').filter(isAbsolute), '/usr/bin', '/bin',
]));
const childEnv = { PATH: searchPaths.join(':'), INITIAL_AGENT_MODE: 'read-only', MODEL_PROVIDER: 'openai' };
const configEnv = ['CODEX_HOME', 'GEMINI_HOME'];
const execEnv = { HOME: homedir(), PATH: childEnv.PATH };
for (const name of configEnv) if (process.env[name]) execEnv[name] = process.env[name];
function executable(name) {
  for (const directory of searchPaths) {
    const candidate = join(directory, name);
    try {
      accessSync(candidate, constants.X_OK);
      if (statSync(candidate).isFile()) return candidate;
    } catch {}
  }
}
const codexPackage = import.meta.resolve('@agentclientprotocol/codex-acp/package.json');
const codexManifest = JSON.parse(await readFile(new URL(codexPackage), 'utf8'));
const codexAdapter = new URL(typeof codexManifest.bin === 'string' ? codexManifest.bin : codexManifest.bin['codex-acp'], codexPackage);
const installed = id => executable(providers[id].executable);
function launch(id) {
  if (id === 'codex') return [process.execPath, decodeURIComponent(codexAdapter.pathname)];
  return [installed(id), ...providers[id].args];
}
const registry = {
  list: () => Object.keys(providers),
  resolve: id => launch(id),
};
const active = new Map();
const toolKeys = new Map();
const localTools = createResearchTools(dataUrl);
const mcpPath = decodeURIComponent(new URL('./mcp-stdio.mjs', import.meta.url).pathname);
const toolNames = new Set(researchTools.map(tool => tool.name));
const runtime = createAcpRuntime({
  cwd: work, sessionStore: store, agentRegistry: registry, timeoutMs: 180000,
  permissionMode: 'deny-all', fs: false, terminal: false,
  agentProcessEnv: childEnv, agentProcessEnvAllow: configEnv,
  mcpServers({ sessionKey }) {
    const key = randomUUID();
    toolKeys.set(sessionKey, key);
    return [{ name: 'trig-research', command: process.execPath, args: [mcpPath, socket, sessionKey],
      env: [{ name: 'TRIG_MCP_SESSION', value: key }] }];
  },
  async onPermissionRequest({ raw }) {
    const title = raw.toolCall?.title ?? '';
    const match = /^(?:mcp\.trig-research\.|(?:mcp__)?trig[-_]research__|Run mcp_trig-research_)([a-z_]+)$/.exec(title);
    if (match && toolNames.has(match[1])) return { outcome: 'allow_once' };
  },
});

class RequestError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}
function provider(id) {
  if (!Object.hasOwn(providers, id)) throw new RequestError(400, 'Unknown research provider.');
  if (!installed(id)) throw new RequestError(412, 'Install this provider’s CLI in AI Providers.');
  return id;
}
function id(value) {
  if (typeof value !== 'string' || !/^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i.test(value)) {
    throw new RequestError(400, 'Invalid research identifier.');
  }
  return value.toLowerCase();
}
function assetKey(value) {
  if (typeof value !== 'string' || !/^[a-zA-Z0-9:]{5,128}$/.test(value)) {
    throw new RequestError(400, 'Invalid asset.');
  }
  return value;
}
const conversationFile = join(state, 'conversation.json');
async function readJSON(path) {
  try { return JSON.parse(await readFile(path, 'utf8')); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
}
async function saveConversation(record) {
  const staging = join(state, `.${randomUUID()}.tmp`);
  await writeFile(staging, JSON.stringify(record), { flag: 'wx', mode: 0o600 });
  await rename(staging, conversationFile);
}
async function restoreConversation() {
  const saved = await readJSON(conversationFile);
  if (saved) return saved;
  const legacy = join(state, 'threads');
  const files = await readdir(legacy).catch(error => {
    if (error.code === 'ENOENT') return [];
    throw error;
  });
  const records = await Promise.all(files.filter(name => /^[a-f0-9-]{36}\.json$/.test(name))
    .map(name => readJSON(join(legacy, name))));
  const latest = records.filter(record => record?.recordId && Object.hasOwn(providers, record.provider) && record.updatedAt)
    .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))[0];
  if (latest) await saveConversation(latest);
  return latest;
}
let conversation = await restoreConversation();
function friendly(error) {
  if (error instanceof RequestError) return error.message;
  const description = String(error?.message ?? '');
  if (/quota|rate.limit|429/i.test(description)) return 'The provider rate-limited this request. Try again shortly.';
  if (/auth|log\s?in|sign\s?in|unauthorized|\b401\b/i.test(description)) return 'Sign in to the provider’s CLI, then check the connection in AI Providers.';
  if (/timed?\s*out|timeout/i.test(description)) return 'The provider timed out. Try again.';
  return 'The local agent couldn’t complete this request.';
}
function json(res, status, data) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(data));
}
async function readBody(req) {
  let size = 0;
  const chunks = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > 48 * 1024) throw new RequestError(413, 'This research request is too large.');
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString() || '{}') ?? {}; }
  catch { throw new RequestError(400, 'Invalid research request.'); }
}
async function checkAccount(agent) {
  if (agent !== 'codex') return;
  try {
    const result = await exec(installed(agent), ['login', 'status'], { cwd: work, env: execEnv, timeout: 10000 });
    if (/logged in using chatgpt/i.test(result.stdout + result.stderr)) return;
  } catch {}
  throw new RequestError(412, 'Run codex login and sign in with ChatGPT, then check again.');
}
async function probe(agent) {
  provider(agent);
  await checkAccount(agent);
  const catalog = await inspectAgentModels({
    cwd: work, agentCommand: launch(agent), timeoutMs: 22000,
    agentProcessEnv: childEnv, agentProcessEnvAllow: configEnv,
  });
  return { models: (catalog?.availableModels ?? catalog?.availableModelIds?.map(modelId => ({ modelId, name: modelId })) ?? [])
    .map(({ modelId, name }) => ({ id: modelId, name: name || modelId })) };
}
async function requestTelegram(entry, asset) {
  const requestId = randomUUID();
  const signal = AbortSignal.any([entry.controller.signal, AbortSignal.timeout(24_000)]);
  const result = new Promise(resolve => {
    if (signal.aborted) { resolve({ status: 'unavailable' }); return; }
    const abort = () => resolve({ status: 'unavailable', reason: 'Telegram did not respond in time.' });
    signal.addEventListener('abort', abort, { once: true });
    entry.telegram.set(requestId, value => {
      signal.removeEventListener('abort', abort);
      resolve(value);
    });
  });
  try {
    await entry.send({ type: 'tool_request', requestId, asset });
    return await result;
  } finally { entry.telegram.delete(requestId); }
}
async function turn(res, input) {
  const agent = provider(input.provider);
  const threadId = id(input.threadId);
  const asset = assetKey(input.asset);
  const turnId = id(input.turnId);
  const question = typeof input.question === 'string' ? input.question.trim() : '';
  if (!question || question.length > 8000 || hasResearchContext(question)) {
    throw new RequestError(400, 'Enter a valid research question.');
  }
  if (active.size) throw new RequestError(409, 'This conversation already has an active response.');
  const previous = conversation;
  if (previous && (previous.id !== threadId || previous.provider !== agent)) {
    throw new RequestError(409, 'Research is already connected to another provider or session. Reopen Research to restore it.');
  }
  const controller = new AbortController();
  res.once('close', () => controller.abort());
  res.writeHead(200, { 'Content-Type': 'application/x-ndjson', 'Cache-Control': 'no-store' });
  const send = async value => {
    if (res.destroyed) return;
    if (!res.write(JSON.stringify(value) + '\n') && !res.destroyed) {
      await once(res, 'drain', { signal: controller.signal }).catch(() => {});
    }
  };
  const assetLabel = key => typeof input[key] === 'string' ? input[key].slice(0, 120) : '';
  const pool = typeof input.assetPool === 'string' && /^[a-zA-Z0-9]{32,66}$/.test(input.assetPool) ? input.assetPool : undefined;
  const entry = { turnId, asset, symbol: assetLabel('assetSymbol'), name: assetLabel('assetName'),
    network: assetLabel('assetNetwork'), pool, controller, send, telegram: new Map() };
  active.set(threadId, entry);
  try {
    await send({ type: 'starting' });
    await checkAccount(agent);
    const handle = await runtime.ensureSession({
      sessionKey: threadId, agent, mode: 'persistent',
      ...(previous?.nativeId ? { resumeSessionId: previous.nativeId } : {}),
    });
    if (controller.signal.aborted) {
      await send({ type: 'done', status: 'cancelled' });
      return;
    }
    if (typeof input.model === 'string' && input.model && input.model !== previous?.model) {
      const status = await runtime.getStatus({ handle });
      if (status.models?.currentModelId !== input.model) await runtime.setModel({ handle, model: input.model });
    }
    const next = {
      id: threadId, provider: agent, nativeId: handle.agentSessionId ?? handle.backendSessionId,
      recordId: handle.acpxRecordId, model: input.model || previous?.model,
      updatedAt: new Date().toISOString(),
    };
    await saveConversation(next);
    conversation = next;
    await send({ type: 'conversation', conversation: summary(next) });
    const job = runtime.startTurn({ handle, mode: 'prompt', requestId: turnId,
      text: marketPrompt(question, entry), signal: controller.signal });
    let providerFailure;
    for await (const event of job.events) {
      if (event.type !== 'text_delta' || event.stream === 'thought') continue;
      const failure = codexFailure(agent, event.text, event.messageId);
      if (failure) providerFailure = failure;
      else await send({ type: 'delta', text: event.text });
    }
    const result = await job.result;
    if (providerFailure) await send({ type: 'error', message: providerFailure });
    else if (result.status === 'failed') await send({ type: 'error', message: friendly(result.error) });
    else await send({ type: 'done', status: result.status });
  } catch (error) {
    if (controller.signal.aborted) await send({ type: 'done', status: 'cancelled' });
    else await send({ type: 'error', message: friendly(error) });
  } finally {
    controller.abort();
    active.delete(threadId);
    res.end();
  }
}
function summary({ id, provider, model }) { return { id, provider, model }; }

const server = createServer(async (req, res) => {
  try {
    const input = await readBody(req);
    switch (req.url) {
      case '/mcp-call': {
        const threadId = id(input.threadId);
        const entry = active.get(threadId);
        const key = toolKeys.get(threadId);
        if (!entry || !key || req.headers.authorization !== `Bearer ${key}` || entry.controller.signal.aborted) {
          throw new RequestError(403, 'This research conversation has no active turn.');
        }
        const result = await localTools(input.name, input.input ?? {}, {
          asset: entry.asset, symbol: entry.symbol, name: entry.name, pool: entry.pool, signal: entry.controller.signal,
          telegram: asset => requestTelegram(entry, asset),
        });
        return json(res, 200, result);
      }
      case '/tool-result': {
        const entry = active.get(id(input.threadId));
        const requestId = id(input.requestId);
        if (entry?.turnId === id(input.turnId)) {
          const resolve = entry.telegram.get(requestId);
          entry.telegram.delete(requestId);
          resolve?.(input.result ?? { status: 'unavailable' });
        }
        return json(res, 200, {});
      }
      case '/providers': return json(res, 200, Object.keys(providers).map(id => ({ id, installed: Boolean(installed(id)) })));
      case '/probe': return json(res, 200, await probe(input.provider));
      case '/conversation': {
        const current = conversation;
        const snapshot = current?.recordId ? await store.load(current.recordId) : null;
        return json(res, 200, { conversation: current ? summary(current) : null,
          messages: researchMessages(snapshot, current?.provider) });
      }
      case '/turn': return await turn(res, input);
      case '/stop': {
        const entry = active.get(id(input.threadId));
        if (entry?.turnId === id(input.turnId)) entry.controller.abort();
        return json(res, 200, {});
      }
      default: return json(res, 404, { error: 'Research action not found.' });
    }
  } catch (error) { json(res, error.status ?? 503, { error: friendly(error) }); }
});
server.listen(socket);
process.stdin.resume();
process.stdin.once('end', () => {
  server.close();
  for (const entry of active.values()) entry.controller.abort();
  runtime.shutdown().finally(() => process.exit(0));
});
