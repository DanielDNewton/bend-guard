# bend-guard: the entry the checker host calls (design.md component 3, plan
# Tasks 2.1, 2.2 and 3.1). Policy = translator (ModelTools.Model.tool) then
# the generic guard (Guard) over the rule table of ./Rules.bend. The same
# text is bend/templates/Policy.bend, which tools/gen.mjs copies next to a
# project's generated Rules.bend. Defs keep the Policy. prefix, so their JS
# export keys are exactly "Policy.decide", "Policy.run", "Policy.meaning",
# "Policy.next_cwds" and "Policy.paths" (bend/NOTES.md naming rule 5).

import Base
import ../core/Types.bend as T
import ../core/Call.bend as Call
import ../core/Guard.bend as Guard
import ../core/ModelTools.bend as ModelTools
import ./Rules.bend as Rules

# The project laws (project/LAWS.bend) are stated over this: the guard with
# the meaning m free.
def Policy.run_m(x: T.Ctx, m: T.Meaning, t: String, a: T.ClefAnswer) -> T.Verdict:
  Guard.run_m(Rules.table(), x, m, t, a)

# p is under a NoChange or NoReadOrChange path of some project.
def Policy.in_rule_zone(p: T.Path) -> Bool:
  Guard.in_rule_zone(Rules.table(), p)

# What the call does.
def Policy.meaning(c: T.Call) -> T.Meaning:
  ModelTools.Model.tool(c)

# The step for a call: Done{v}, or Consult Clef first.
def Policy.decide(+c: T.Call) -> T.Step:
  Guard.decide_m(Rules.table(), Call.ctx(c), ModelTools.Model.tool(c), Guard.clef_text(c))

# The final verdict for a call and Clef's answer (NoAnswer when not asked).
def Policy.run(+c: T.Call, a: T.ClefAnswer) -> T.Verdict:
  Policy.run_m(Call.ctx(c), ModelTools.Model.tool(c), Guard.clef_text(c), a)

# The possible shell folders after the call ran.
def Policy.next_cwds(c: T.Call) -> List<&2, String>:
  ModelTools.Model.next_cwds_tool(c)

# Path.show of every path the call touches (for the log).
def Policy.paths(c: T.Call) -> List<&2, String>:
  ModelTools.Model.paths_tool(c)

# Running a call is the translator, then the policy on its meaning: every
# law stated over Policy.run_m (with m free) holds for every real call.
law run_is_translator_then_policy:
  for +c: T.Call
  for a: T.ClefAnswer
  {Policy.run(c, a) == Policy.run_m(Call.ctx(c), ModelTools.Model.tool(c), Guard.clef_text(c), a) : T.Verdict}

def run_is_translator_then_policy(c, a):
  {==}
