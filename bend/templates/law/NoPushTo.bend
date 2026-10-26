# Rule {{LINE}}: outside log-only mode, a git push that names the branch {{BRANCH}}, run in a folder inside {{ROOT_SHOW}}, is denied.
law {{LAW}}:
  for +x: T.Ctx
  for +m: T.Meaning
  for t: String
  for a: T.ClefAnswer
  for +as1: List<&2, T.Action>
  for +dir: T.Path
  for +force: Bool
  for +all: Bool
  for +r1: List<&2, String>
  for +r2: List<&2, String>
  for +unsure: Bool
  for +as2: List<&2, T.Action>
  for h0: {Call.Ctx.log_only(x) == False{} : Bool}
  for h1: {Meaning.actions(m) == List.append(&2, T.Action, as1, T.GitPush{dir, force, all, List.append(&2, String, r1, "{{BRANCH}}" <> r2), unsure} <> as2) : List<&2, T.Action>}
  for h2: {Path.under(dir, {{ROOT}}) == True{} : Bool}
  {Verdict.is_deny(Guard.run_m(Rules.table(), x, m, t, a)) == True{} : Bool}
