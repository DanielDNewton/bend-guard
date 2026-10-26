# Rule {{LINE}}: outside log-only mode, a call that changes anything under {{ROOT_SHOW}}/{{REL}} is denied.
law {{LAW}}:
  for +x: T.Ctx
  for +m: T.Meaning
  for t: String
  for a: T.ClefAnswer
  for +p: T.Path
  for h0: {Call.Ctx.log_only(x) == False{} : Bool}
  for h1: {Meaning.changes(m, p) == True{} : Bool}
  for h2: {Path.under(p, Path.child({{ROOT}}, "{{REL}}")) == True{} : Bool}
  {Verdict.is_deny(Guard.run_m(Rules.table(), x, m, t, a)) == True{} : Bool}
