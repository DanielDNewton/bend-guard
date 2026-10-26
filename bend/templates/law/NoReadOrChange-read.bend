# Rule {{LINE}}: outside log-only mode, a call that reads a file under {{ROOT_SHOW}}/{{REL}} is denied.
law {{LAW}}:
  for +x: T.Ctx
  for +m: T.Meaning
  for t: String
  for a: T.ClefAnswer
  for +as1: List<&2, T.Action>
  for +q: T.Path
  for +as2: List<&2, T.Action>
  for h0: {Call.Ctx.log_only(x) == False{} : Bool}
  for h1: {Meaning.actions(m) == List.append(&2, T.Action, as1, T.Read{q} <> as2) : List<&2, T.Action>}
  for h2: {Path.under(q, Path.child({{ROOT}}, "{{REL}}")) == True{} : Bool}
  {Verdict.is_deny(Guard.run_m(Rules.table(), x, m, t, a)) == True{} : Bool}
