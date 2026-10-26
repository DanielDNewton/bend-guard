# Outside log-only mode, a plain read of a file that no rule names, that is not protected or the key file, not behind a link and in no double-check zone, is allowed whatever Clef says (when the project and home folders were read).
law reads_allowed:
  for +x: T.Ctx
  for +t: String
  for +a: T.ClefAnswer
  for +p: T.Path
  for h0: {Path.is_sentinel(Call.Ctx.root(x)) == False{} : Bool}
  for h0b: {Path.is_sentinel(Call.Ctx.home(x)) == False{} : Bool}
  for h2: {Guard.in_rule_zone(Rules.table(), p) == False{} : Bool}
  for h3: {Protect.covers(Rules.table(), x, p) == False{} : Bool}
  for h4: {Path.overlaps(p, Protect.key_file(Call.Ctx.home(x))) == False{} : Bool}
  for h5: {Call.Ctx.log_only(x) == False{} : Bool}
  for h6: {Guard.no_rule_names(Rules.table(), p) == True{} : Bool}
  for h7: {Guard.no_link(x, p) == True{} : Bool}
  {Verdict.is_allow(Guard.run_m(Rules.table(), x, T.Known{[T.Read{p}]}, t, a)) == True{} : Bool}
