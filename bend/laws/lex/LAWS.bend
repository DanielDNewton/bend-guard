# bend-guard: laws for the bash lexer's variables (round 2, P10; design.md
# component 2, layer 1). A variable that is set gives back exactly its
# value; one that is unset or forgotten gives nothing (so a later $NAME is
# refused); a value joins the word as its own characters, as if written out
# in quotes; and a text that sets a variable and uses it gives the same
# tokens as the text with the value written out, for any home folder.
#
# Only one sample text is a law: the proof kernel (bend --verdict) evaluates
# the whole lexer for each sample and runs out of fuel on longer ones. The
# other samples (heredocs, cd &&, refused forms) are corpus cases in
# tests/corpus/r2-grammar.jsonl.

import Base
import ../../core/Types.bend as T
import ../../core/Path.bend as Path
import ../../core/Lex.bend as Lex

law var_set_get:
  for e: List<&2, T.Arg>
  for +n: String
  for v: String
  {Lex.var.get(Lex.var.set(e, n, v), n) == Some{v} : Maybe<&2, String>}

law var_del_get:
  for e: List<&2, T.Arg>
  for +n: String
  {Lex.var.get(Lex.var.del(e, n), n) == None{} : Maybe<&2, String>}

# names assigned after && are forgotten when the chain ends
law var_del_all_get:
  for ns: List<&2, String>
  for +e: List<&2, T.Arg>
  for +n: String
  {Lex.var.get(Lex.var.del_all(n <> ns, e), n) == None{} : Maybe<&2, String>}

# the value's characters join the word in order and unchanged
law var_ins_value:
  for v: String
  for cur: String
  {Lex.var.ins(Some{v}, cur) == String.append(String.reverse(v), cur) : String}

law subst_quoted:
  for h: String
  {Lex.toks(Lex.bash(h, "D=src; cat \"$D/app.ts\"")) == Lex.toks(Lex.bash(h, "cat \"src/app.ts\"")) : Maybe<&2, List<&2, T.Tok>>}
