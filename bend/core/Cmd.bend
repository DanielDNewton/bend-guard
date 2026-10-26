# bend-guard: the splitter (plan.md Task 1.5; design.md component 2, layer 2).
# Cmd.split groups lexer tokens into simple commands, each with its argv and
# redirects, or gives None (unknown). ; && || | and a newline all end a
# command, since every part may run. Imported as Cmd:  import ./Cmd.bend as Cmd

import Base
import ./Types.bend as T

# a redirect waiting for its target word
type SplitWait is Data:
  SplitWait.No{}
  SplitWait.Out{}
  SplitWait.App{}
  SplitWait.In{}

# words that make the rest shell syntax, not a command (bash and PowerShell),
# compared in lower case
def split.keywords() -> List<&2, String>:
  ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "select", "function", "coproc", "time", "[[", "]]", "!", "{", "}", "foreach", "switch", "try", "catch", "finally", "trap", "filter", "workflow", "class", "enum", "data", "param", "begin", "process", "end", "dynamicparam", "using", "configuration", "parallel", "sequence", "inlinescript"]

def split.elem(+x: String, xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      String.eq(x, h) || split.elem(x, t)

# the command name: not an environment prefix (any = in it, so NAME=value and
# NAME+=value) and not a keyword
def split.first_ok(+w: String) -> Bool:
  Bool.not(String.contains(w, "=") || split.elem(String.to_lower(w), split.keywords()))

# argv (in order) is a command: it has a name, and the name is allowed
def split.cmd_ok(argv: List<&2, String>) -> Bool:
  match argv:
    case Nil{}:
      False{}
    case w <> t:
      split.first_ok(w)

def split.simple(argv: List<&2, String>, rs: List<&2, T.Redir>) -> T.Simple:
  T.Simple{List.reverse(&2, String, argv), List.reverse(&2, T.Redir, rs)}

# one simple command, and aa: it directly follows && (so it runs only when
# the command before it succeeded)
type Part is Data:
  Part.Mk{s: T.Simple, aa: Bool}

def split.fin(ok: Bool, acc: List<&2, Part>) -> Maybe<&2, List<&2, Part>>:
  match ok:
    case True{}:
      Some{List.reverse(&2, Part, acc)}
    case False{}:
      None{}

def split.is_and(t: T.Tok) -> Bool:
  match t:
    case T.And{}:
      True{}
    case _:
      False{}

# argv and rs are the current command's words and redirects, reversed; acc the
# finished commands, reversed; ok: every finished command was allowed; aa: the
# current command follows &&
def split.go(ts: List<&2, T.Tok>, w: SplitWait, +argv: List<&2, String>, rs: List<&2, T.Redir>, acc: List<&2, Part>, ok: Bool, aa: Bool) -> Maybe<&2, List<&2, Part>>:
  match ts w:
    # the end, or a single ; or newline at the end
    case Nil{} SplitWait.No{}:
      split.fin(ok && split.cmd_ok(List.reverse(&2, String, argv)), Part.Mk{split.simple(argv, rs), aa} <> acc)
    case Con{T.Seq{}, Nil{}} SplitWait.No{}:
      split.fin(ok && split.cmd_ok(List.reverse(&2, String, argv)), Part.Mk{split.simple(argv, rs), aa} <> acc)
    # a redirect with no target word
    case Nil{} _:
      None{}
    # words
    case Con{T.Word{x}, t} SplitWait.No{}:
      split.go(t, SplitWait.No{}, x <> argv, rs, acc, ok, aa)
    case Con{T.Word{x}, t} SplitWait.Out{}:
      split.go(t, SplitWait.No{}, argv, T.ToFile{x, False{}} <> rs, acc, ok, aa)
    case Con{T.Word{x}, t} SplitWait.App{}:
      split.go(t, SplitWait.No{}, argv, T.ToFile{x, True{}} <> rs, acc, ok, aa)
    case Con{T.Word{x}, t} SplitWait.In{}:
      split.go(t, SplitWait.No{}, argv, T.FromFile{x} <> rs, acc, ok, aa)
    # an operator where a redirect target should be
    case Con{x, t} SplitWait.Out{}:
      None{}
    case Con{x, t} SplitWait.App{}:
      None{}
    case Con{x, t} SplitWait.In{}:
      None{}
    # redirects
    case Con{T.Out{fd}, t} SplitWait.No{}:
      split.go(t, SplitWait.Out{}, argv, rs, acc, ok, aa)
    case Con{T.Tok.App{fd}, t} SplitWait.No{}:
      split.go(t, SplitWait.App{}, argv, rs, acc, ok, aa)
    case Con{T.In{}, t} SplitWait.No{}:
      split.go(t, SplitWait.In{}, argv, rs, acc, ok, aa)
    # ; && || | newline: the command ends (an empty one is refused)
    case Con{x, t} SplitWait.No{}:
      split.go(t, SplitWait.No{}, [], [], Part.Mk{split.simple(argv, rs), aa} <> acc, ok && split.cmd_ok(List.reverse(&2, String, argv)), split.is_and(x))

# Cmd.parts(ts): the simple commands of a token list, each with whether it
# follows &&, or None (unknown)
def parts(ts: List<&2, T.Tok>) -> Maybe<&2, List<&2, Part>>:
  split.go(ts, SplitWait.No{}, [], [], [], True{}, False{})

def split.simples(ps: List<&2, Part>) -> List<&2, T.Simple>:
  match ps:
    case Nil{}:
      []
    case Con{Part.Mk{s, aa}, t}:
      s <> split.simples(t)

def split.m(m: Maybe<&2, List<&2, Part>>) -> Maybe<&2, List<&2, T.Simple>>:
  match m:
    case Some{ps}:
      Some{split.simples(ps)}
    case None{}:
      None{}

# Cmd.split(ts): the simple commands of a token list, or None (unknown)
def split(ts: List<&2, T.Tok>) -> Maybe<&2, List<&2, T.Simple>>:
  split.m(parts(ts))
