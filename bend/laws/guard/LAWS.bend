# bend-guard: laws of the generic policy Guard.run_m (plan Tasks 2.2, 2.3),
# stated with the meaning m free, so they hold whatever the translator says.
# Proven in PROOF.bend beside this file. bend/NOTES.md section 8 maps each
# law to the parts of Guard.bend it unfolds.

import Base
import ../../core/Types.bend as T
import ../../core/Verdict.bend as Verdict
import ../../core/Meaning.bend as Meaning
import ../../core/Call.bend as Call
import ../../core/Guard.bend as Guard

# A command bend-guard does not understand is never allowed unless the user said yes to this exact call (log-only mode included).
law unknown_never_allowed:
  for +table: List<&2, T.Project>
  for +x: T.Ctx
  for +m: T.Meaning
  for +t: String
  for +a: T.ClefAnswer
  for +h1: {Meaning.is_unknown(m) == True{} : Bool}
  for h2: {Call.Ctx.dan_said_yes(x) == False{} : Bool}
  {Verdict.is_allow(Guard.run_m(table, x, m, t, a)) == False{} : Bool}

# Where no person can answer (a subagent, or nobody to ask), bend-guard never asks: it allows or refuses.
law no_ask_without_person:
  for +table: List<&2, T.Project>
  for +x: T.Ctx
  for +m: T.Meaning
  for +t: String
  for +a: T.ClefAnswer
  for h: {Guard.can_ask(x) == False{} : Bool}
  {Verdict.is_ask(Guard.run_m(table, x, m, t, a)) == False{} : Bool}

# Clef's answer can only make a verdict stricter, never looser.
law combine_monotone:
  for +base: T.Verdict
  for +q: T.ClefQ
  for +a: T.ClefAnswer
  {Nat.is_le(Verdict.rank(base), Verdict.rank(Guard.combine(base, q, a))) == True{} : Bool}

# Settling an ask (asking the user, or refusing when nobody can be asked) keeps a stricter verdict at least as strict.
law finish_monotone:
  for +x: T.Ctx
  for +v1: T.Verdict
  for +v2: T.Verdict
  for h: {Nat.is_le(Verdict.rank(v1), Verdict.rank(v2)) == True{} : Bool}
  {Nat.is_le(Verdict.rank(Guard.finish(x, v1)), Verdict.rank(Guard.finish(x, v2))) == True{} : Bool}

# Whatever Clef answers (or if it does not answer), the final verdict is at least as strict as without Clef.
law clef_cannot_loosen:
  for +table: List<&2, T.Project>
  for +x: T.Ctx
  for +m: T.Meaning
  for +t: String
  for +a: T.ClefAnswer
  {Nat.is_le(Verdict.rank(Guard.run_m_without_clef(table, x, m, t)), Verdict.rank(Guard.run_m(table, x, m, t, a))) == True{} : Bool}

# A shell command bend-guard does not understand that names a path a NoReadOrChange rule keeps unreadable is refused, whatever Clef answers, in log-only mode too (round 3, P3).
law named_noread_unknown_denied:
  for +table: List<&2, T.Project>
  for +x: T.Ctx
  for +m: T.Meaning
  for +t: String
  for +a: T.ClefAnswer
  for +h1: {Meaning.is_unknown(m) == True{} : Bool}
  for h2: {Guard.noread.hit(table, x, t) == True{} : Bool}
  {Verdict.is_deny(Guard.run_m(table, x, m, t, a)) == True{} : Bool}
