// Test-only MCP server for tests/live/run.mjs (scenario mcp-check). Never
// installed. Plain node, no packages: newline-delimited JSON-RPC 2.0 over
// stdio, the MCP stdio transport. One tool, 'echo', that returns its text.
//
//   node tests/live/mcp-stub.mjs     (Claude Code starts it from --mcp-config)

import readline from 'node:readline'

const TOOLS = [
  {
    name: 'echo',
    description: 'Returns the text it is given. Test-only; does nothing else.',
    inputSchema: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'] },
  },
]

const send = msg => process.stdout.write(JSON.stringify(msg) + '\n')
const reply = (id, result) => send({ jsonrpc: '2.0', id, result })
const fail = (id, code, message) => send({ jsonrpc: '2.0', id, error: { code, message } })

function handle(msg) {
  const { id, method, params } = msg
  const isRequest = id !== undefined && id !== null
  switch (method) {
    case 'initialize':
      return reply(id, {
        protocolVersion: typeof params?.protocolVersion === 'string' ? params.protocolVersion : '2025-06-18',
        capabilities: { tools: {} },
        serverInfo: { name: 'stub', version: '0.0.1' },
      })
    case 'ping':
      return reply(id, {})
    case 'tools/list':
      return reply(id, { tools: TOOLS })
    case 'tools/call': {
      if (params?.name !== 'echo') return fail(id, -32602, `unknown tool ${String(params?.name)}`)
      const text = String(params?.arguments?.text ?? '')
      return reply(id, { content: [{ type: 'text', text: `echo: ${text}` }], isError: false })
    }
    default:
      // Notifications (notifications/initialized and the like) get no answer.
      if (isRequest) fail(id, -32601, `method not found: ${String(method)}`)
  }
}

const rl = readline.createInterface({ input: process.stdin })
rl.on('line', line => {
  if (!line.trim()) return
  let msg
  try {
    msg = JSON.parse(line)
  } catch {
    return send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } })
  }
  for (const m of Array.isArray(msg) ? msg : [msg]) handle(m)
})
rl.on('close', () => process.exit(0))
