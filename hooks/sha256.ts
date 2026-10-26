// bend-guard: SHA-256 of text (its UTF-8 bytes) as lower-case hex. The hooks
// module has crypto.subtle but no Node, so this wraps it.
//
// Brief: bend2_test\docs\build-brief.md, "Claude Code mod API".

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))
  const bytes = new Uint8Array(digest)
  let hex = ''
  for (let i = 0; i < bytes.length; i++) hex += bytes[i].toString(16).padStart(2, '0')
  return hex
}
