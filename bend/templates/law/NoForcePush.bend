# Rule {{LINE}}: outside log-only mode, a forced git push (--force, -f, +ref, --mirror) run in a folder inside {{ROOT_SHOW}} is denied.
law {{LAW}}:
  for +x: T.Ctx
  for +m: T.Meaning
  for t: String
  for a: T.ClefAnswer
  for +as1: List<&2, T.Action>
  for +dir: T.Path
  for +all: Bool
  for +refs: List<&2, String>
  for +unsure: Bool
  for +as2: List<&2, T.Action>
  for h0: {Call.Ctx.log_only(x) == False{} : Bool}
  for h1: {Meaning.actions(m) == List.append(&2, T.Action, as1, T.GitPush{dir, True{}, all, refs, unsure} <> as2) : List<&2, T.Action>}
  for h2: {Path.under(dir, {{ROOT}}) == True{} : Bool}
  {Verdict.is_deny(Guard.run_m(Rules.table(), x, m, t, a)) == True{} : Bool}
