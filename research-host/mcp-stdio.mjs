import { request } from 'node:http';
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { ListToolsRequestSchema, CallToolRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { researchTools } from './research-tools.mjs';

const [socketPath, threadId] = process.argv.slice(2);
const credential = process.env.TRIG_MCP_SESSION;
if (!socketPath || !threadId || !credential) process.exit(1);
const server = new Server({ name: 'trig-research', version: '1.0.0' }, { capabilities: { tools: {} } });
server.setRequestHandler(ListToolsRequestSchema, () => ({ tools: researchTools }));
server.setRequestHandler(CallToolRequestSchema, async ({ params }, { signal }) => {
  try {
    const result = await new Promise((resolve, reject) => {
      const req = request({ socketPath, path: '/mcp-call', method: 'POST', signal,
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${credential}` } }, res => {
        let body = '';
        res.setEncoding('utf8');
        res.on('data', chunk => { body += chunk; });
        res.on('error', reject);
        res.on('end', () => {
          try {
            const data = JSON.parse(body);
            if (res.statusCode !== 200) reject(new Error(data.error ?? 'Research tool unavailable.'));
            else resolve(data);
          } catch (error) { reject(error); }
        });
      });
      req.on('error', reject);
      req.end(JSON.stringify({ threadId, name: params.name, input: params.arguments ?? {} }));
    });
    return { content: [{ type: 'text', text: JSON.stringify(result) }], structuredContent: result };
  } catch (error) {
    return { isError: true, content: [{ type: 'text', text: error.message || 'Research tool unavailable.' }] };
  }
});
await server.connect(new StdioServerTransport());
