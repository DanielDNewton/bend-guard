// Test-only plugin for tests/live/run.mjs (scenario "order-probe"): records, in
// the order the engine fires them, every tool.call and tool.check this session
// sees, to the file named by BG_ORDER_LOG. It passes every event on unchanged,
// except that with BG_ORDER_ASK set it answers 'ask' at tool.check for a command
// holding that word. Never installed; loaded only with --plugin-dir.
import type { Register } from 'claude-code'

let lines: string[] = []
let chain: Promise<void> = Promise.resolve()

function note($: any, text: string): Promise<void> {
  chain = chain
    .then(async () => {
      const file = await $.env.get('BG_ORDER_LOG')
      if (typeof file !== 'string' || !file) return
      lines.push(`${new Date().toISOString()} ${text}`)
      await $.fs.write(file, lines.join('\n') + '\n')
    })
    .catch(() => undefined)
  return chain
}

const cmd = (e: any) => String(e?.command ?? e?.input?.command ?? '').slice(0, 80)

export const register: Register = on => {
  on('tool.call', async ($: any, e: any, next: any) => {
    await note($, `tool.call enter ${e?.tool} id=${e?.tool_use_id} agent=${e?.agentId ?? 'main'} ${cmd(e)}`)
    const r = await next(e)
    await note($, `tool.call next-resolved ${e?.tool} id=${e?.tool_use_id} ${r && typeof r === 'object' && 'deny' in r ? 'deny' : r?.isError ? 'error-result' : 'result'}`)
    return r
  }).catch(($: any, e: any, next: any) => next(e))

  on('tool.check', async ($: any, e: any, next: any) => {
    await note($, `tool.check enter ${e?.tool} id=${e?.tool_use_id} agent=${e?.agentId ?? 'main'} approver=${e?.approver ?? 'none'} ${cmd(e)}`)
    const r = await next(e)
    await note($, `tool.check engine-verdict ${e?.tool} id=${e?.tool_use_id} ${r?.decision}`)
    // BG_ORDER_ASK=<word>: answer 'ask' for a command holding that word, to see
    // what the engine does with a plugin's ask in this permission mode.
    const word = await $.env.get('BG_ORDER_ASK')
    if (typeof word === 'string' && word && cmd(e).includes(word)) {
      await note($, `tool.check plugin-answer ask ${e?.tool} id=${e?.tool_use_id}`)
      return { decision: 'ask', reason: 'order-probe: asking on purpose' }
    }
    return r
  }).catch(($: any, e: any, next: any) => next(e))
}

export default register
