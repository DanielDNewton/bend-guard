# bend-guard: the shell lexers (plan.md Tasks 1.3 and 1.4; design.md
# component 2, layer 1). Lex.bash and Lex.pwsh turn command text into words
# and operators (T.Tok), or None when the text uses anything whose meaning is
# not certain: fail closed. `home` replaces the few spellings of the home
# folder whose value is known. Imported as Lex:  import ./Lex.bend as Lex
#
# Each lexer is one recursive def over the text (shrinking argument first),
# with the state in the other arguments:
#   m    where we are (LexMode below)
#   inw  a word is in progress (it may still be empty, after '')
#   wq   that word has a quoted or escaped part
#   cur  the word so far, reversed
#   acc  the tokens so far, reversed
#   ok   no refused form seen yet; checks that need a computed value AND into
#        it, and the text is still read to the end
#   x    (bash only) variables, an assignment in progress, a waiting heredoc
#        and the words with quoted wildcards (LexX below; round 2, P10)
# A refused form that a pattern alone shows returns None at once.

import Base
import ./Types.bend as T
import ./Path.bend as Path

type LexMode is Data:
  LexMode.Un{}           # unquoted
  LexMode.Sq{}           # inside '...'
  LexMode.Dq{}           # inside "..."
  LexMode.Com{}          # bash comment, up to the end of the line
  LexMode.Skip{n: Nat}   # n more characters already handled (an expanded name)
  LexMode.QSkip{n: Nat}  # the same inside "...": back to Dq afterwards
  # a heredoc body (bash): the end line d, strip leading tabs (<<-), raw (a
  # quoted end word, so the body is literal), the line so far (reversed),
  # lead (still in the line's leading tabs)
  LexMode.Hd{d: String, strip: Bool, raw: Bool, line: String, lead: Bool}

# Lex.bash's result: the tokens, and lit: the texts of words whose wildcard
# characters (* ? [) were all quoted or escaped, and that never occur in the
# same text as a word with an unquoted wildcard. Bash does not expand them.
type LexOut is Data:
  LexOut.Mk{toks: List<&2, T.Tok>, lit: List<&2, String>}

# ---- small helpers ----------------------------------------------------------

def lx.is_zero(n: Nat) -> Bool:
  match n:
    case 0n:
      True{}
    case _:
      False{}

def lx.nz(n: Nat) -> Bool:
  Bool.not(lx.is_zero(n))

def lx.pick_n(b: Bool, x: Nat, y: Nat) -> Nat:
  match b:
    case True{}:
      x
    case False{}:
      y

def lx.pick_s(b: Bool, x: String, y: String) -> String:
  match b:
    case True{}:
      x
    case False{}:
      y

def lx.b2n(b: Bool) -> Nat:
  match b:
    case True{}:
      1n
    case False{}:
      0n

# a character that ends an unquoted word: space, tab, newline, ; & | < >
def lx.term(c: Char) -> Bool:
  match c:
    case Chr{32}:
      True{}
    case Chr{9}:
      True{}
    case Chr{10}:
      True{}
    case Chr{59}:
      True{}
    case Chr{38}:
      True{}
    case Chr{124}:
      True{}
    case Chr{60}:
      True{}
    case Chr{62}:
      True{}
    case _:
      False{}

# the text is at the end of a word
def lx.tend(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{c, r}:
      lx.term(c)

# a control character other than tab and newline, or DEL
def lx.ctl(c: Char) -> Bool:
  match c:
    case Chr{9}:
      False{}
    case Chr{10}:
      False{}
    case Chr{+k}:
      (k < 32 : U32) || U32.is_eq(k, 127)

def lx.nonascii(c: Char) -> Bool:
  match c:
    case Chr{k}:
      (k > 127 : U32)

# no control character anywhere; with ascii, no non-ASCII character either
def lx.clean(s: String, +ascii: Bool, ok: Bool) -> Bool:
  match s:
    case SNil{}:
      ok
    case SCon{+c, r}:
      lx.clean(r, ascii, ok && Bool.not(lx.ctl(c)) && Bool.not(ascii && lx.nonascii(c)))

# number of digits at the start of s
def lx.digits.go(s: String, alive: Bool, n: Nat) -> Nat:
  match s:
    case SNil{}:
      n
    case SCon{c, r}:
      +a = alive && Char.is_digit(c)
      lx.digits.go(r, a, Nat.add(n, lx.b2n(a)))

def lx.digits(s: String) -> Nat:
  lx.digits.go(s, True{}, 0n)

# ---- tokens -------------------------------------------------------------------

# end the word in progress, if any
def lx.push(inw: Bool, cur: String, acc: List<&2, T.Tok>) -> List<&2, T.Tok>:
  match inw:
    case True{}:
      T.Word{String.reverse(cur)} <> acc
    case False{}:
      acc

# a newline is Seq, except at the start, after another Seq, and after && || |
# (where both shells read on into the next line)
def lx.nl(acc: List<&2, T.Tok>) -> List<&2, T.Tok>:
  match acc:
    case Nil{}:
      []
    case Con{T.Seq{}, t}:
      T.Seq{} <> t
    case Con{T.And{}, t}:
      T.And{} <> t
    case Con{T.Or{}, t}:
      T.Or{} <> t
    case Con{T.Pipe{}, t}:
      T.Pipe{} <> t
    case Con{h, t}:
      T.Seq{} <> (h <> t)

def lx.fin(ok: Bool, acc: List<&2, T.Tok>) -> Maybe<&2, List<&2, T.Tok>>:
  match ok:
    case True{}:
      Some{List.reverse(&2, T.Tok, acc)}
    case False{}:
      None{}

def lx.rtok(app: Bool, fd: U32) -> T.Tok:
  match app:
    case True{}:
      T.Tok.App{fd}
    case False{}:
      T.Out{fd}

# the token list just after a redirect: the previous token is > or >>
def lx.after_redir(acc: List<&2, T.Tok>) -> Bool:
  match acc:
    case Con{T.Out{fd}, t}:
      True{}
    case Con{T.Tok.App{fd}, t}:
      True{}
    case _:
      False{}

# the next word is a command name: at the start or after ; && || |
def lx.cmdpos(acc: List<&2, T.Tok>) -> Bool:
  match acc:
    case Nil{}:
      True{}
    case Con{T.Seq{}, t}:
      True{}
    case Con{T.And{}, t}:
      True{}
    case Con{T.Or{}, t}:
      True{}
    case Con{T.Pipe{}, t}:
      True{}
    case _:
      False{}

# ---- the home folder and ~ ------------------------------------------------------

def lx.is_tilde(c: Char) -> Bool:
  match c:
    case Chr{126}:
      True{}
    case _:
      False{}

# the word so far (reversed) starts with ~ and has no / yet: bash is still
# reading a tilde prefix, and any quoted part in it makes ~ a literal folder
def lx.tpre(+cur: String) -> Bool:
  String.ends_with(cur, "~") && Bool.not(String.contains(cur, "/"))

# a quoted or escaped character c may join the word: refused for a quoted ~
# at the start of a word, and inside a tilde prefix
def lx.qok(c: Char, +cur: String) -> Bool:
  Bool.not((lx.is_tilde(c) && String.is_empty(cur)) || lx.tpre(cur))

# an unquoted ~ may join the word: refused after an empty quote ('' then ~ is
# a literal folder) and after = or : (bash expands ~ there)
def lx.utilde(inw: Bool, cur: String) -> Bool:
  match inw cur:
    case False{} _:
      True{}
    case True{} SNil{}:
      False{}
    case True{} SCon{Chr{61}, r}:
      False{}
    case True{} SCon{Chr{58}, r}:
      False{}
    case True{} _:
      True{}

# the home text can stand in for an unquoted bash $HOME: not empty, and
# nothing that bash would split or glob
def lx.hsafe(+h: String) -> Bool:
  Bool.not(String.is_empty(h) || String.contains(h, " ") || String.contains(h, "\t") || String.contains(h, "\n") || String.contains(h, "*") || String.contains(h, "?") || String.contains(h, "["))

# ---- bash helpers -----------------------------------------------------------------

# what the word before > >> < >& is: 0n no word, a word with a quoted part, or
# not all digits; 1n one digit (a file descriptor); 2n several digits (refused)
def bash.fdk.len(all: Bool, n: Nat) -> Nat:
  match all:
    case False{}:
      0n
    case True{}:
      match n:
        case 0n:
          0n
        case 1n+k:
          match k:
            case 0n:
              1n
            case _:
              2n

def bash.fdk(inw: Bool, wq: Bool, +cur: String) -> Nat:
  match inw wq:
    case True{} False{}:
      bash.fdk.len(Nat.is_eq(lx.digits(cur), String.length(cur)), String.length(cur))
    case _ _:
      0n

def bash.fdval(cur: String) -> U32:
  match cur:
    case SCon{Chr{k}, r}:
      (k - 48 : U32)
    case SNil{}:
      1

# the tokens after > or >> (app); k from bash.fdk; pushed: acc with the word
# in progress ended (used when that word is not a descriptor)
def bash.gt(k: Nat, +cur: String, pushed: List<&2, T.Tok>, acc: List<&2, T.Tok>, app: Bool) -> List<&2, T.Tok>:
  match k:
    case 0n:
      lx.rtok(app, 1) <> pushed
    case _:
      lx.rtok(app, bash.fdval(cur)) <> acc

# the tokens after N>&M or >&M, which is dropped with its descriptor word
def bash.dup_acc(k: Nat, pushed: List<&2, T.Tok>, acc: List<&2, T.Tok>) -> List<&2, T.Tok>:
  match k:
    case 0n:
      pushed
    case _:
      acc

def bash.dup.dash(r: String) -> Bool:
  match r:
    case SCon{Chr{45}, t}:
      lx.tend(t)
    case _:
      False{}

def bash.dup.num(+n: Nat, +r: String) -> Nat:
  lx.pick_n(lx.nz(n) && lx.tend(String.drop(r, n)), n, 0n)

# r is the text after >&: the length of M when M is digits or - and the word
# ends there, else 0n (refused: >&file writes a file)
def bash.dup(+r: String) -> Nat:
  lx.pick_n(bash.dup.dash(r), 1n, bash.dup.num(lx.digits(r), r))

# >&word with no descriptor word before it and a target that is not digits
# or - (f is True): bash sends stdout and stderr to the file word, so it is
# read as > (T.Out{1}) and the next word is the file. Otherwise the >&M is
# skipped (Skip{n}; Skip{0n} refuses the text).
def bash.dup_mode(f: Bool, n: Nat) -> LexMode:
  match f:
    case True{}:
      LexMode.Un{}
    case False{}:
      LexMode.Skip{n}

def bash.dup_out(f: Bool, acc: List<&2, T.Tok>) -> List<&2, T.Tok>:
  match f:
    case True{}:
      T.Out{1} <> acc
    case False{}:
      acc

# ---- bash: variables (round 2, P10) -------------------------------------------------
# NAME=WORD and export NAME=WORD standing alone as a statement (at the start,
# or after ; or a newline, and followed by ; && a newline, a comment or the
# end) record NAME and give no token. Later $NAME, ${NAME} and "$NAME" are
# replaced by the value, as if the value had been written there. Names are
# compared with Path.Seg.eq (laws/lex). Anything else that looks like an
# assignment to NAME, and unset NAME, forget NAME, so a later $NAME is refused.

def var.is_start(c: Char) -> Bool:
  match c:
    case Chr{+k}:
      ((k > 64 : U32) && (k < 91 : U32)) || ((k > 96 : U32) && (k < 123 : U32)) || U32.is_eq(k, 95)

def var.is_char(+c: Char) -> Bool:
  var.is_start(c) || Char.is_digit(c)

# n plus the number of name characters at the start of s
def var.ilen.go(s: String, alive: Bool, n: Nat) -> Nat:
  match s alive:
    case SNil{} _:
      n
    case _ False{}:
      n
    case SCon{c, t} True{}:
      +a = var.is_char(c)
      var.ilen.go(t, a, Nat.add(n, lx.b2n(a)))

# the length of the name at the start of s (a letter or _ first), else 0n
def var.ilen(s: String) -> Nat:
  match s:
    case SNil{}:
      0n
    case SCon{+c, +t}:
      lx.pick_n(var.is_start(c), var.ilen.go(SCon{c, t}, True{}, 0n), 0n)

# r is the text after "${": the length of NAME} plus 2 for the braces
def var.blen(+r: String) -> Nat:
  +k = var.ilen(r)
  lx.pick_n(lx.nz(k) && String.starts_with(String.drop(r, k), "}"), Nat.add(k, 2n), 0n)

# r is the text after $: how many characters NAME or {NAME} take, else 0n
def var.len(+r: String) -> Nat:
  match r:
    case SCon{Chr{123}, t}:
      var.blen(t)
    case _:
      var.ilen(r)

# r is the text after $: the name
def var.name(+r: String) -> String:
  match r:
    case SCon{Chr{123}, +t}:
      String.take(t, var.ilen(t))
    case _:
      String.take(r, var.ilen(r))

def var.get.k(c: Bool, v: String, rest: Maybe<&2, String>) -> Maybe<&2, String>:
  match c:
    case True{}:
      Some{v}
    case False{}:
      rest

# the value of name n in the variables e (the first entry wins)
def var.get(e: List<&2, T.Arg>, +n: String) -> Maybe<&2, String>:
  match e:
    case Nil{}:
      None{}
    case Con{T.Arg{k, v}, t}:
      var.get.k(Path.Seg.eq(k, n), v, var.get(t, n))

def var.del.k(c: Bool, a: T.Arg, rest: List<&2, T.Arg>) -> List<&2, T.Arg>:
  match c:
    case True{}:
      rest
    case False{}:
      a <> rest

# the variables without name n
def var.del(e: List<&2, T.Arg>, +n: String) -> List<&2, T.Arg>:
  match e:
    case Nil{}:
      []
    case Con{T.Arg{+k, v}, t}:
      var.del.k(Path.Seg.eq(k, n), T.Arg{k, v}, var.del(t, n))

# the variables with n set to v
def var.set(e: List<&2, T.Arg>, +n: String, v: String) -> List<&2, T.Arg>:
  T.Arg{n, v} <> var.del(e, n)

def var.elem(+x: String, xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      String.eq(x, h) || var.elem(x, t)

def var.pre(+x: String, ps: List<&2, String>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case p <> t:
      String.starts_with(x, p) || var.pre(x, t)

# names whose value changes what bash or a later program does (compared in
# lower case, since Windows programs read the environment that way), and
# bash's own changing variables. Final review: openssl, ssl and requests_
# (OPENSSL_CONF loads a module; SSLKEYLOGFILE writes a file; SSL_CERT_FILE
# and REQUESTS_CA_BUNDLE read one) for pip, npm, git and curl.
def var.denied() -> List<&2, String>:
  ["_", "ifs", "path", "home", "userprofile", "cdpath", "env", "ps1", "ps2", "ps3", "ps4", "shellopts", "bashopts", "globignore", "prompt_command", "pwd", "oldpwd", "posixly_correct", "tmpdir", "tmp", "temp", "shell", "comspec", "pathext", "systemroot", "systemdrive", "windir", "appdata", "localappdata", "programdata", "homedrive", "homepath", "pager", "manpager", "editor", "visual", "browser", "prefix", "uid", "euid", "ppid", "groups", "random", "srandom", "seconds", "lineno", "histcmd", "funcname", "bashpid", "epochseconds", "epochrealtime", "dirstack", "optind", "optarg", "opterr", "hostfile", "mailpath", "mail", "mailcheck", "fignore", "tmout", "inputrc", "term", "editor"]

def var.denied_pre() -> List<&2, String>:
  ["bash_", "ld_", "dyld_", "git_", "node_", "npm_", "yarn_", "pnpm_", "python", "less", "grep_", "awk", "msys", "cygwin", "xdg_", "lc_", "lang", "ssh_", "gnupg", "curl", "http", "all_proxy", "no_proxy", "java", "_java", "perl", "ruby", "claude", "anthropic", "comp_", "hist", "programfiles", "commonprogramfiles", "gh_", "github_", "ripgrep_", "wget", "pip_", "openssl", "ssl", "requests_"]

# short names programs read from the environment
def var.short_denied() -> List<&2, String>:
  ["tz", "os", "cc", "cxx", "cpp", "ar", "as", "ld", "nm", "fc", "tmp", "pwd", "ifs", "env", "_"]

# A name that may be assigned and substituted: not a known name, and either
# short (1 to 3 characters, not one of the short names programs read) or all
# lower case. Any other name may already be in the environment, where an
# assignment reaches programs started later, so it is not understood (final
# round).
def var.name_ok(+n: String) -> Bool:
  +l = String.to_lower(n)
  +known = var.elem(l, var.denied()) || var.pre(l, var.denied_pre())
  +short = Nat.is_le(String.length(n), 3n) && Bool.not(var.elem(l, var.short_denied()))
  Bool.not(known) && (short || String.eq(n, l))

# the value of the name after $ (r is the text after it): HOME and
# USERPROFILE are the home folder; other names come from the variables
def var.is_letter(c: Char) -> Bool:
  match c:
    case Chr{+k}:
      ((k > 64 : U32) && (k < 91 : U32)) || ((k > 96 : U32) && (k < 123 : U32))

# home starts with a drive letter and a colon (C:\Users\...)
def var.hdrive(home: String) -> Bool:
  match home:
    case SCon{d, SCon{Chr{58}, t}}:
      var.is_letter(d)
    case _:
      False{}

def var.slash(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{Chr{92}, t}:
      SCon{'/', var.slash(t)}
    case SCon{c, t}:
      SCon{c, var.slash(t)}

# bash's own spelling of the home folder: Git Bash sets HOME to /c/Users/...
# (USERPROFILE keeps the Windows form). A home without a drive letter is
# used as it is.
def var.hpos(+home: String) -> String:
  match home:
    case SCon{d, SCon{Chr{58}, t}}:
      "/" ++ String.to_lower(SCon{d, SNil{}}) ++ var.slash(t)
    case _:
      home

def var.val.k(h: Bool, u: Bool, +home: String, e: List<&2, T.Arg>, +nm: String) -> Maybe<&2, String>:
  match h u:
    case True{} _:
      Some{var.hpos(home)}
    case False{} True{}:
      Some{home}
    case False{} False{}:
      var.get(e, nm)

def var.val(e: List<&2, T.Arg>, +home: String, +r: String) -> Maybe<&2, String>:
  +nm = var.name(r)
  var.val.k(String.eq(nm, "HOME"), String.eq(nm, "USERPROFILE"), home, e, nm)

def var.str(v: Maybe<&2, String>) -> String:
  match v:
    case Some{s}:
      s
    case None{}:
      ""

def var.some(v: Maybe<&2, String>) -> Bool:
  match v:
    case Some{s}:
      True{}
    case None{}:
      False{}

# after the name: not a line continuation (bash would join it to the name)
def var.follow(s: String) -> Bool:
  match s:
    case SCon{Chr{92}, SCon{Chr{10}, t}}:
      False{}
    case SCon{Chr{92}, SNil{}}:
      False{}
    case _:
      True{}

# HOME when home has no drive letter: the text may differ from bash's, which
# names the same folder only as a whole path, so it stays at the start of a
# word (and out of assignments)
def var.is_home(+r: String, +home: String) -> Bool:
  String.eq(var.name(r), "HOME") && Bool.not(var.hdrive(home))

# a use of value v (its name takes n characters of r) may join the word
# cur: a known name, properly ended, not inside a tilde prefix, and not a
# ~ at the start of a word (bash keeps an expanded ~ literal)
def var.qok(+v: Maybe<&2, String>, +n: Nat, +r: String, +cur: String, +home: String) -> Bool:
  lx.nz(n) && var.some(v) && var.follow(String.drop(r, n)) && Bool.not(lx.tpre(cur)) && Bool.not(String.is_empty(cur) && String.starts_with(var.str(v), "~")) && (String.is_empty(cur) || Bool.not(var.is_home(r, home)))

# unquoted, also nothing bash would split or glob (and not empty)
def var.bok(+v: Maybe<&2, String>, +n: Nat, +r: String, +cur: String, +home: String) -> Bool:
  var.qok(v, n, r, cur, home) && lx.hsafe(var.str(v))

# the word so far (reversed) with the value's characters added
def var.ins(v: Maybe<&2, String>, cur: String) -> String:
  String.append(String.reverse(var.str(v)), cur)

# ---- bash: heredocs (round 2, P10) --------------------------------------------------
# <<'D', <<"D", <<-'D' and <<D: the body runs from the next line to a line
# that is exactly D (after its leading tabs with <<-). It is standard input
# and gives no token. With a bare D the body may hold no $ ` or \. One
# heredoc per line; a body with no end line is refused.

type LexHq is Data:
  LexHq.Mk{n: Nat, d: String, strip: Bool, raw: Bool}   # n: characters after <<, 0n refused

def hd.n(q: LexHq) -> Nat:
  match q:
    case LexHq.Mk{n, d, st, rw}:
      n

def hd.is_blank(c: Char) -> Bool:
  match c:
    case Chr{32}:
      True{}
    case Chr{9}:
      True{}
    case _:
      False{}

def hd.blanks(s: String, alive: Bool, n: Nat) -> Nat:
  match s alive:
    case SNil{} _:
      n
    case _ False{}:
      n
    case SCon{c, t} True{}:
      +a = hd.is_blank(c)
      hd.blanks(t, a, Nat.add(n, lx.b2n(a)))

# characters before the quote q (or a newline)
def hd.qlen(s: String, +q: U32, alive: Bool, n: Nat) -> Nat:
  match s alive:
    case SNil{} _:
      n
    case _ False{}:
      n
    case SCon{c, t} True{}:
      +k = Char.to_u32(c)
      +a = Bool.not(U32.is_eq(k, q) || U32.is_eq(k, 10))
      hd.qlen(t, q, a, Nat.add(n, lx.b2n(a)))

def hd.bare_char(+c: Char) -> Bool:
  var.is_char(c) || U32.is_eq(Char.to_u32(c), 45) || U32.is_eq(Char.to_u32(c), 46)

def hd.blen(s: String, alive: Bool, n: Nat) -> Nat:
  match s alive:
    case SNil{} _:
      n
    case _ False{}:
      n
    case SCon{c, t} True{}:
      +a = hd.bare_char(c)
      hd.blen(t, a, Nat.add(n, lx.b2n(a)))

def hd.at(s: String, +q: U32) -> Bool:
  match s:
    case SCon{Chr{k}, t}:
      U32.is_eq(k, q)
    case SNil{}:
      False{}

def hd.qword.k(+t: String, +q: U32, +k: Nat, pre: Nat, st: Bool, dq: Bool, +d: String) -> LexHq:
  +rest = String.drop(t, k)
  +ok = lx.nz(k) && hd.at(rest, q) && lx.tend(String.drop(rest, 1n)) && Bool.not(dq && (String.contains(d, "$") || String.contains(d, "`") || String.contains(d, "\\")))
  LexHq.Mk{lx.pick_n(ok, Nat.add(pre, Nat.add(k, 2n)), 0n), d, st, True{}}

# t follows an opening quote q
def hd.qword(+t: String, +q: U32, pre: Nat, st: Bool, dq: Bool) -> LexHq:
  +k = hd.qlen(t, q, True{}, 0n)
  hd.qword.k(t, q, k, pre, st, dq, String.take(t, k))

def hd.bword(+r: String, +k: Nat, pre: Nat, st: Bool) -> LexHq:
  LexHq.Mk{lx.pick_n(lx.nz(k) && lx.tend(String.drop(r, k)), Nat.add(pre, k), 0n), String.take(r, k), st, False{}}

def hd.word(+r: String, pre: Nat, st: Bool) -> LexHq:
  match r:
    case SCon{Chr{39}, +t}:
      hd.qword(t, 39, pre, st, False{})
    case SCon{Chr{34}, +t}:
      hd.qword(t, 34, pre, st, True{})
    case _:
      hd.bword(r, hd.blen(r, True{}, 0n), pre, st)

def hd.refuse(bad: Bool, q: LexHq) -> LexHq:
  match q:
    case LexHq.Mk{n, d, st, rw}:
      LexHq.Mk{lx.pick_n(bad, 0n, n), d, st, rw}

# r is the text after <<: the end word and how many characters it takes
# (<<< is refused)
def hd.parse(+r: String) -> LexHq:
  +st = String.starts_with(r, "-")
  +r1 = String.drop(r, lx.b2n(st))
  +b = hd.blanks(r1, True{}, 0n)
  hd.refuse(String.starts_with(r, "<"), hd.word(String.drop(r1, b), Nat.add(lx.b2n(st), b), st))

# a character an unquoted heredoc body may not hold: $ ` \
def hd.special(c: Char) -> Bool:
  match c:
    case Chr{36}:
      True{}
    case Chr{96}:
      True{}
    case Chr{92}:
      True{}
    case _:
      False{}

def hd.is_end(line: String, d: String) -> Bool:
  String.eq(String.reverse(line), d)

def hd.next(e: Bool, d: String, st: Bool, rw: Bool) -> LexMode:
  match e:
    case True{}:
      LexMode.Un{}
    case False{}:
      LexMode.Hd{d, st, rw, "", True{}}

# ---- bash: the extra state ----------------------------------------------------------

def lx.is_glob(c: Char) -> Bool:
  match c:
    case Chr{42}:
      True{}
    case Chr{63}:
      True{}
    case Chr{91}:
      True{}
    case _:
      False{}

def lx.has_glob(s: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{c, t}:
      lx.is_glob(c) || lx.has_glob(t)

# an assignment word in progress: No (not one), Name (only unquoted name
# characters so far), Val{name} (NAME= seen unquoted; the rest is the value)
type LexAsg is Data:
  LexAsg.No{}
  LexAsg.Name{}
  LexAsg.Val{name: String}

# a heredoc waiting for the end of its line
type LexHd is Data:
  LexHd.No{}
  LexHd.Wait{d: String, strip: Bool, raw: Bool}

# env: the variables; an: the word in progress as an assignment; drop: an
# assignment statement was just dropped, so the ; or && after it gives no
# token; un: inside an unset command (its words are forgotten); ug, qg: the
# word in progress has an unquoted, or a quoted or escaped, wildcard; hd: a
# heredoc waiting; qws, uws: words with only quoted wildcards, and words with
# an unquoted wildcard; cs: names assigned after && (forgotten when the &&
# chain ends, since the assignment may not have run)
type LexX is Data:
  LexX.Mk{env: List<&2, T.Arg>, an: LexAsg, drop: Bool, un: Bool, ug: Bool, qg: Bool, hd: LexHd, qws: List<&2, String>, uws: List<&2, String>, cs: List<&2, String>}

def bx.new() -> LexX:
  LexX.Mk{[], LexAsg.No{}, False{}, False{}, False{}, False{}, LexHd.No{}, [], [], []}

def bx.env(x: LexX) -> List<&2, T.Arg>:
  match x:
    case LexX.Mk{e, an, dr, un, ug, qg, wh, qw, uw, cs}:
      e

def bx.drop(x: LexX) -> Bool:
  match x:
    case LexX.Mk{e, an, dr, un, ug, qg, wh, qw, uw, cs}:
      dr

def bx.hdnone(x: LexX) -> Bool:
  match x:
    case LexX.Mk{e, an, dr, un, ug, qg, LexHd.No{}, qw, uw, cs}:
      True{}
    case _:
      False{}

def bx.lit.k(seen: Bool, w: String, rest: List<&2, String>) -> List<&2, String>:
  match seen:
    case True{}:
      rest
    case False{}:
      w <> rest

def bx.lit.go(qw: List<&2, String>, +uw: List<&2, String>) -> List<&2, String>:
  match qw:
    case Nil{}:
      []
    case +w <> t:
      bx.lit.k(var.elem(w, uw), w, bx.lit.go(t, uw))

def bx.lit(x: LexX) -> List<&2, String>:
  match x:
    case LexX.Mk{e, an, dr, un, ug, qg, wh, qw, uw, cs}:
      bx.lit.go(qw, uw)

def asg.q(a: LexAsg) -> LexAsg:
  match a:
    case LexAsg.Val{n}:
      LexAsg.Val{n}
    case _:
      LexAsg.No{}

def asg.start(b: Bool) -> LexAsg:
  match b:
    case True{}:
      LexAsg.Name{}
    case False{}:
      LexAsg.No{}

def asg.name(ic: Bool, eq: Bool, +cur: String) -> LexAsg:
  match ic eq:
    case True{} _:
      LexAsg.Name{}
    case False{} True{}:
      LexAsg.Val{String.reverse(cur)}
    case False{} False{}:
      LexAsg.No{}

def asg.more(an: LexAsg, +c: Char, +cur: String) -> LexAsg:
  match an:
    case LexAsg.Name{}:
      asg.name(var.is_char(c), U32.is_eq(Char.to_u32(c), 61), cur)
    case LexAsg.Val{n}:
      LexAsg.Val{n}
    case LexAsg.No{}:
      LexAsg.No{}

# an unquoted character c joins the word (inw: one was in progress)
def asg.u(an: LexAsg, +c: Char, inw: Bool, +cur: String) -> LexAsg:
  match inw:
    case False{}:
      asg.start(var.is_start(c))
    case True{}:
      asg.more(an, c, cur)

def bx.uchar(x: LexX, +c: Char, inw: Bool, +cur: String) -> LexX:
  match x:
    case LexX.Mk{e, an, dr, un, ug, qg, wh, qw, uw, cs}:
      LexX.Mk{e, asg.u(an, c, inw, cur), dr, un, ug || lx.is_glob(c), qg, wh, qw, uw, cs}

# a quoted or escaped character c joins the word
def bx.qchar(x: LexX, c: Char) -> LexX:
  match x:
    case LexX.Mk{e, an, dr, un, ug, qg, wh, qw, uw, cs}:
      LexX.Mk{e, asg.q(an), dr, un, ug, qg || lx.is_glob(c), wh, qw, uw, cs}

# a quote opens
def bx.qopen(x: LexX) -> LexX:
  match x:
    case LexX.Mk{e, an, dr, un, ug, qg, wh, qw, uw, cs}:
      LexX.Mk{e, asg.q(an), dr, un, ug, qg, wh, qw, uw, cs}

# a variable's value joins the word (quoted: inside "...")
def bx.sub(x: LexX, +v: Maybe<&2, String>, quoted: Bool) -> LexX:
  match x:
    case LexX.Mk{e, an, dr, un, ug, qg, wh, qw, uw, cs}:
      LexX.Mk{e, asg.q(an), dr, un, ug, qg || (quoted && lx.has_glob(var.str(v))), wh, qw, uw, cs}

# the variables without the names in ns
def var.del_all(ns: List<&2, String>, e: List<&2, T.Arg>) -> List<&2, T.Arg>:
  match ns:
    case Nil{}:
      e
    case +n <> t:
      var.del_all(t, var.del(e, n))

# after &&: no assignment waiting for its separator and no unset
def bx.and(x: LexX) -> LexX:
  match x:
    case LexX.Mk{e, an, dr, un, ug, qg, wh, qw, uw, cs}:
      LexX.Mk{e, an, False{}, False{}, ug, qg, wh, qw, uw, cs}

# after ; || |: the same, and the && chain has ended, so the names assigned
# inside it are forgotten
def bx.sep(x: LexX) -> LexX:
  match x:
    case LexX.Mk{e, an, dr, un, ug, qg, wh, qw, uw, +cs}:
      LexX.Mk{var.del_all(cs, e), an, False{}, False{}, ug, qg, wh, qw, uw, []}

# after a newline: the same as ;, and a waiting heredoc has begun
def bx.nl(x: LexX) -> LexX:
  match x:
    case LexX.Mk{e, an, dr, un, ug, qg, wh, qw, uw, +cs}:
      LexX.Mk{var.del_all(cs, e), an, False{}, False{}, ug, qg, LexHd.No{}, qw, uw, []}

# the mode after a newline: a waiting heredoc's body, or unquoted text
def bx.nlmode(x: LexX) -> LexMode:
  match x:
    case LexX.Mk{e, an, dr, un, ug, qg, LexHd.Wait{d, st, rw}, qw, uw, cs}:
      LexMode.Hd{d, st, rw, "", True{}}
    case _:
      LexMode.Un{}

def bx.hdset(x: LexX, q: LexHq) -> LexX:
  match x q:
    case LexX.Mk{e, an, dr, un, ug, qg, wh, qw, uw, cs} LexHq.Mk{n, d, st, rw}:
      LexX.Mk{e, an, dr, un, ug, qg, LexHd.Wait{d, st, rw}, qw, uw, cs}

# ; or && after a dropped assignment gives no token
def sep.push(dr: Bool, t: T.Tok, acc: List<&2, T.Tok>) -> List<&2, T.Tok>:
  match dr:
    case True{}:
      acc
    case False{}:
      t <> acc

# where an assignment may stand alone: 1n at the start or after ; or a
# newline (it always runs); 3n right after && (it runs only if the commands
# before it in the && chain succeeded, so the name lasts only to the chain's
# end); 0n elsewhere. An export just before it counts the same.
def asg.pos0(acc: List<&2, T.Tok>) -> Nat:
  match acc:
    case Nil{}:
      1n
    case Con{T.Seq{}, t}:
      1n
    case Con{T.And{}, t}:
      3n
    case _:
      0n

def asg.pos.w(e: Bool, t: List<&2, T.Tok>) -> Nat:
  match e:
    case True{}:
      asg.pos0(t)
    case False{}:
      0n

# An export before NAME=WORD is not a local assignment: the export stays a
# command word, which is not understood, because its value would reach every
# program started later in the text (final round).
def asg.pos(acc: List<&2, T.Tok>) -> Nat:
  match acc:
    case Con{T.Word{w}, t}:
      0n
    case _:
      asg.pos0(acc)

# drop the export before an assignment that stands alone
def asg.pop(acc: List<&2, T.Tok>) -> List<&2, T.Tok>:
  match acc:
    case Con{T.Word{w}, t}:
      t
    case _:
      acc

# drop the && before an assignment that follows it (its own separator is kept)
def asg.pop_and(acc: List<&2, T.Tok>) -> List<&2, T.Tok>:
  match acc:
    case Con{T.And{}, t}:
      t
    case _:
      acc

def asg.value(+n: String, +cur: String) -> String:
  String.drop(String.reverse(cur), Nat.add(String.length(n), 1n))

def be.asg.an(an: LexAsg, ok: Bool, +pos: Nat, +cur: String) -> Nat:
  match an:
    case LexAsg.Val{+n}:
      lx.pick_n(ok && lx.nz(pos) && var.name_ok(n) && Bool.not(String.contains(asg.value(n, cur), "~")), pos, 0n)
    case _:
      0n

def be.asg(fo: Bool, +cur: String, +acc: List<&2, T.Tok>, x: LexX) -> Nat:
  match x:
    case LexX.Mk{e, an, dr, un, ug, qg, wh, qw, uw, cs}:
      be.asg.an(an, fo && Bool.not(ug), asg.pos(acc), cur)

def be.kind.k(a: Nat) -> Nat:
  match a:
    case 0n:
      2n
    case _:
      a

# what the word in progress is when it ends (fo: what follows lets an
# assignment stand alone): 0n no word, 1n an assignment that stands alone
# as a statement, 3n one right after && (both give no token), 2n a word
def be.kind(fo: Bool, inw: Bool, +cur: String, +acc: List<&2, T.Tok>, +x: LexX) -> Nat:
  match inw:
    case False{}:
      0n
    case True{}:
      be.kind.k(be.asg(fo, cur, acc, x))

def be.acc.k(k: Nat, +cur: String, acc: List<&2, T.Tok>) -> List<&2, T.Tok>:
  match k:
    case 0n:
      acc
    case 1n+j:
      match j:
        case 0n:
          asg.pop(acc)
        case 1n:
          T.Word{String.reverse(cur)} <> acc
        case _:
          asg.pop_and(asg.pop(acc))

# the tokens once the word in progress ends
def be.acc(fo: Bool, inw: Bool, +cur: String, +acc: List<&2, T.Tok>, +x: LexX) -> List<&2, T.Tok>:
  be.acc.k(be.kind(fo, inw, cur, acc, x), cur, acc)

def asg.set(an: LexAsg, +cur: String, e: List<&2, T.Arg>) -> List<&2, T.Arg>:
  match an:
    case LexAsg.Val{+n}:
      var.set(e, n, asg.value(n, cur))
    case _:
      e

def asg.forget(an: LexAsg, e: List<&2, T.Arg>) -> List<&2, T.Arg>:
  match an:
    case LexAsg.Val{n}:
      var.del(e, n)
    case _:
      e

def be.unset(un: Bool, +w: String, e: List<&2, T.Arg>) -> List<&2, T.Arg>:
  match un:
    case True{}:
      var.del(e, w)
    case False{}:
      e

def be.addif(b: Bool, w: String, xs: List<&2, String>) -> List<&2, String>:
  match b:
    case True{}:
      w <> xs
    case False{}:
      xs

# a word w ends (cp: it is a command name)
def be.word(+w: String, cp: Bool, e: List<&2, T.Arg>, an: LexAsg, +un: Bool, +ug: Bool, qg: Bool, wh: LexHd, qw: List<&2, String>, uw: List<&2, String>, cs: List<&2, String>) -> LexX:
  LexX.Mk{be.unset(un, w, asg.forget(an, e)), LexAsg.No{}, False{}, un || (cp && String.eq(w, "unset")), False{}, False{}, wh, be.addif(qg && Bool.not(ug), w, qw), be.addif(ug, w, uw), cs}

def bx.reset(x: LexX) -> LexX:
  match x:
    case LexX.Mk{e, an, dr, un, ug, qg, wh, qw, uw, cs}:
      LexX.Mk{e, LexAsg.No{}, dr, un, False{}, False{}, wh, qw, uw, cs}

def bx.asg(+cur: String, x: LexX) -> LexX:
  match x:
    case LexX.Mk{e, an, dr, un, ug, qg, wh, qw, uw, cs}:
      LexX.Mk{asg.set(an, cur, e), LexAsg.No{}, True{}, un, False{}, False{}, wh, qw, uw, cs}

def asg.name_of(an: LexAsg) -> String:
  match an:
    case LexAsg.Val{n}:
      n
    case _:
      ""

# an assignment right after &&: set, and remembered in cs; its separator stays
def bx.asg3(+cur: String, x: LexX) -> LexX:
  match x:
    case LexX.Mk{e, +an, dr, un, ug, qg, wh, qw, uw, cs}:
      LexX.Mk{asg.set(an, cur, e), LexAsg.No{}, False{}, un, False{}, False{}, wh, qw, uw, asg.name_of(an) <> cs}

def bx.word(+w: String, cp: Bool, x: LexX) -> LexX:
  match x:
    case LexX.Mk{e, an, dr, un, ug, qg, wh, qw, uw, cs}:
      be.word(w, cp, e, an, un, ug, qg, wh, qw, uw, cs)

def be.x.k(k: Nat, +cur: String, +acc: List<&2, T.Tok>, x: LexX) -> LexX:
  match k:
    case 0n:
      bx.reset(x)
    case 1n+j:
      match j:
        case 0n:
          bx.asg(cur, x)
        case 1n:
          bx.word(String.reverse(cur), lx.cmdpos(acc), x)
        case _:
          bx.asg3(cur, x)

# the extra state once the word in progress ends
def be.x(fo: Bool, inw: Bool, +cur: String, +acc: List<&2, T.Tok>, +x: LexX) -> LexX:
  be.x.k(be.kind(fo, inw, cur, acc, x), cur, acc, x)

# what follows a word that ended at a blank lets an assignment stand alone:
# more blanks, then the end, a newline, a comment, ; (not ;;) or &&
def asg.follow(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{Chr{32}, t}:
      asg.follow(t)
    case SCon{Chr{9}, t}:
      asg.follow(t)
    case SCon{Chr{10}, t}:
      True{}
    case SCon{Chr{35}, t}:
      True{}
    case SCon{Chr{59}, SCon{Chr{59}, t}}:
      False{}
    case SCon{Chr{59}, t}:
      True{}
    case SCon{Chr{38}, SCon{Chr{38}, t}}:
      True{}
    case _:
      False{}

# a ~ starting an assignment's value (NAME=~ or NAME=~/...): bash puts the
# home folder there; r is the text after the ~
def asg.tilde.an(an: LexAsg, +cur: String) -> Bool:
  match an:
    case LexAsg.Val{+n}:
      String.is_empty(asg.value(n, cur))
    case _:
      False{}

def asg.tilde(x: LexX, +cur: String, +r: String, +home: String) -> Bool:
  match x:
    case LexX.Mk{e, an, dr, un, ug, qg, wh, qw, uw, cs}:
      asg.tilde.an(an, cur) && var.hdrive(home) && (String.starts_with(r, "/") || lx.tend(r))

def bash.fin(ok: Bool, acc: List<&2, T.Tok>, x: LexX) -> Maybe<&2, LexOut>:
  match ok:
    case True{}:
      Some{LexOut.Mk{List.reverse(&2, T.Tok, acc), bx.lit(x)}}
    case False{}:
      None{}

# ---- Lex.bash ---------------------------------------------------------------------

def bash.go(s: String, m: LexMode, +inw: Bool, +wq: Bool, +cur: String, +acc: List<&2, T.Tok>, ok: Bool, +home: String, +x: LexX) -> Maybe<&2, LexOut>:
  match s m inw:
    # end of text
    case SNil{} LexMode.Un{} _:
      +wk = be.kind(True{}, inw, cur, acc, x)
      bash.fin(ok && bx.hdnone(x), be.acc.k(wk, cur, acc), be.x.k(wk, cur, acc, x))
    case SNil{} LexMode.Com{} _:
      bash.fin(ok && bx.hdnone(x), acc, x)
    case SNil{} LexMode.Hd{d, st, rw, line, ld} _:
      bash.fin(ok && hd.is_end(line, d), acc, x)
    case SNil{} _ _:
      None{}
    # characters already handled ($NAME, >&1, a heredoc's end word)
    case SCon{c, r} LexMode.Skip{n} _:
      match n:
        case 0n:
          bash.go(r, LexMode.Un{}, inw, wq, cur, acc, False{}, home, x)
        case 1n+k:
          match k:
            case 0n:
              bash.go(r, LexMode.Un{}, inw, wq, cur, acc, ok, home, x)
            case _:
              bash.go(r, LexMode.Skip{k}, inw, wq, cur, acc, ok, home, x)
    case SCon{c, r} LexMode.QSkip{n} _:
      match n:
        case 0n:
          bash.go(r, LexMode.Dq{}, inw, wq, cur, acc, False{}, home, x)
        case 1n+k:
          match k:
            case 0n:
              bash.go(r, LexMode.Dq{}, inw, wq, cur, acc, ok, home, x)
            case _:
              bash.go(r, LexMode.QSkip{k}, inw, wq, cur, acc, ok, home, x)
    # heredoc body
    case SCon{Chr{10}, r} LexMode.Hd{+d, st, rw, line, ld} _:
      bash.go(r, hd.next(hd.is_end(line, d), d, st, rw), False{}, False{}, "", acc, ok, home, x)
    case SCon{Chr{9}, r} LexMode.Hd{d, True{}, rw, line, True{}} _:
      bash.go(r, LexMode.Hd{d, True{}, rw, line, True{}}, False{}, False{}, "", acc, ok, home, x)
    case SCon{+c, r} LexMode.Hd{d, st, +rw, line, ld} _:
      bash.go(r, LexMode.Hd{d, st, rw, SCon{c, line}, False{}}, False{}, False{}, "", acc, ok && (rw || Bool.not(hd.special(c))), home, x)
    # comment
    case SCon{Chr{10}, r} LexMode.Com{} _:
      bash.go(r, bx.nlmode(x), False{}, False{}, "", lx.nl(acc), ok, home, bx.nl(x))
    case SCon{c, r} LexMode.Com{} _:
      bash.go(r, LexMode.Com{}, inw, wq, cur, acc, ok, home, x)
    # '...': literal
    case SCon{Chr{39}, r} LexMode.Sq{} _:
      bash.go(r, LexMode.Un{}, True{}, True{}, cur, acc, ok, home, x)
    case SCon{+c, r} LexMode.Sq{} _:
      bash.go(r, LexMode.Sq{}, True{}, True{}, SCon{c, cur}, acc, ok && lx.qok(c, cur), home, bx.qchar(x, c))
    # "...": literal; \ escapes only $ ` " \ and newline; ` and \$ refused;
    # $NAME and ${NAME} of a known variable (or HOME, USERPROFILE) give its value
    case SCon{Chr{34}, r} LexMode.Dq{} _:
      bash.go(r, LexMode.Un{}, True{}, True{}, cur, acc, ok, home, x)
    case SCon{Chr{36}, +r} LexMode.Dq{} _:
      +n = var.len(r)
      +v = var.val(bx.env(x), home, r)
      bash.go(r, LexMode.QSkip{n}, True{}, True{}, var.ins(v, cur), acc, ok && var.qok(v, n, r, cur, home), home, bx.sub(x, v, True{}))
    case SCon{Chr{96}, r} LexMode.Dq{} _:
      None{}
    case SCon{Chr{92}, SCon{Chr{10}, r}} LexMode.Dq{} _:
      bash.go(r, LexMode.Dq{}, True{}, True{}, cur, acc, ok, home, x)
    case SCon{Chr{92}, SCon{Chr{34}, r}} LexMode.Dq{} _:
      bash.go(r, LexMode.Dq{}, True{}, True{}, SCon{Chr{34}, cur}, acc, ok && lx.qok(Chr{34}, cur), home, bx.qchar(x, Chr{34}))
    case SCon{Chr{92}, SCon{Chr{92}, r}} LexMode.Dq{} _:
      bash.go(r, LexMode.Dq{}, True{}, True{}, SCon{Chr{92}, cur}, acc, ok && lx.qok(Chr{92}, cur), home, bx.qchar(x, Chr{92}))
    case SCon{Chr{92}, SCon{Chr{36}, r}} LexMode.Dq{} _:
      None{}
    case SCon{Chr{92}, SCon{Chr{96}, r}} LexMode.Dq{} _:
      None{}
    case SCon{+c, r} LexMode.Dq{} _:
      bash.go(r, LexMode.Dq{}, True{}, True{}, SCon{c, cur}, acc, ok && lx.qok(c, cur), home, bx.qchar(x, c))
    # unquoted: backslash
    case SCon{Chr{92}, SCon{Chr{10}, r}} LexMode.Un{} _:
      bash.go(r, LexMode.Un{}, inw, wq, cur, acc, ok, home, x)
    case SCon{Chr{92}, SNil{}} LexMode.Un{} _:
      None{}
    case SCon{Chr{92}, SCon{+c, r}} LexMode.Un{} _:
      bash.go(r, LexMode.Un{}, True{}, True{}, SCon{c, cur}, acc, ok && lx.qok(c, cur), home, bx.qchar(x, c))
    # unquoted: quotes
    case SCon{Chr{39}, r} LexMode.Un{} _:
      bash.go(r, LexMode.Sq{}, True{}, True{}, cur, acc, ok && Bool.not(lx.tpre(cur)), home, bx.qopen(x))
    case SCon{Chr{34}, r} LexMode.Un{} _:
      bash.go(r, LexMode.Dq{}, True{}, True{}, cur, acc, ok && Bool.not(lx.tpre(cur)), home, bx.qopen(x))
    # unquoted: word ends
    case SCon{Chr{32}, +r} LexMode.Un{} _:
      +fo = asg.follow(r)
      +wk = be.kind(fo, inw, cur, acc, x)
      bash.go(r, LexMode.Un{}, False{}, False{}, "", be.acc.k(wk, cur, acc), ok, home, be.x.k(wk, cur, acc, x))
    case SCon{Chr{9}, +r} LexMode.Un{} _:
      +fo = asg.follow(r)
      +wk = be.kind(fo, inw, cur, acc, x)
      bash.go(r, LexMode.Un{}, False{}, False{}, "", be.acc.k(wk, cur, acc), ok, home, be.x.k(wk, cur, acc, x))
    case SCon{Chr{10}, r} LexMode.Un{} _:
      +wk = be.kind(True{}, inw, cur, acc, x)
      bash.go(r, bx.nlmode(x), False{}, False{}, "", lx.nl(be.acc.k(wk, cur, acc)), ok, home, bx.nl(be.x.k(wk, cur, acc, x)))
    # # at the start of a word starts a comment (inside a word it is a letter)
    case SCon{Chr{35}, r} LexMode.Un{} False{}:
      bash.go(r, LexMode.Com{}, False{}, False{}, "", acc, ok, home, x)
    # operators
    case SCon{Chr{59}, +r} LexMode.Un{} _:
      +fo = Bool.not(String.starts_with(r, ";"))
      +wk = be.kind(fo, inw, cur, acc, x)
      +x1 = be.x.k(wk, cur, acc, x)
      bash.go(r, LexMode.Un{}, False{}, False{}, "", sep.push(bx.drop(x1), T.Seq{}, be.acc.k(wk, cur, acc)), ok, home, bx.sep(x1))
    case SCon{Chr{38}, SCon{Chr{38}, r}} LexMode.Un{} _:
      +wk = be.kind(True{}, inw, cur, acc, x)
      +x1 = be.x.k(wk, cur, acc, x)
      bash.go(r, LexMode.Un{}, False{}, False{}, "", sep.push(bx.drop(x1), T.And{}, be.acc.k(wk, cur, acc)), ok, home, bx.and(x1))
    # &>file and &>>file send stdout and stderr to the file: read as > and >>
    case SCon{Chr{38}, SCon{Chr{62}, SCon{Chr{62}, r}}} LexMode.Un{} _:
      +wk = be.kind(False{}, inw, cur, acc, x)
      bash.go(r, LexMode.Un{}, False{}, False{}, "", T.Tok.App{1} <> be.acc.k(wk, cur, acc), ok, home, be.x.k(wk, cur, acc, x))
    case SCon{Chr{38}, SCon{Chr{62}, r}} LexMode.Un{} _:
      +wk = be.kind(False{}, inw, cur, acc, x)
      bash.go(r, LexMode.Un{}, False{}, False{}, "", T.Out{1} <> be.acc.k(wk, cur, acc), ok, home, be.x.k(wk, cur, acc, x))
    case SCon{Chr{38}, r} LexMode.Un{} _:
      None{}
    case SCon{Chr{124}, SCon{Chr{124}, r}} LexMode.Un{} _:
      +wk = be.kind(False{}, inw, cur, acc, x)
      bash.go(r, LexMode.Un{}, False{}, False{}, "", T.Or{} <> be.acc.k(wk, cur, acc), ok, home, bx.sep(be.x.k(wk, cur, acc, x)))
    case SCon{Chr{124}, SCon{Chr{38}, r}} LexMode.Un{} _:
      None{}
    case SCon{Chr{124}, r} LexMode.Un{} _:
      +wk = be.kind(False{}, inw, cur, acc, x)
      bash.go(r, LexMode.Un{}, False{}, False{}, "", T.Pipe{} <> be.acc.k(wk, cur, acc), ok, home, bx.sep(be.x.k(wk, cur, acc, x)))
    # redirects
    case SCon{Chr{62}, SCon{Chr{62}, SCon{Chr{38}, r}}} LexMode.Un{} _:
      None{}
    case SCon{Chr{62}, SCon{Chr{62}, r}} LexMode.Un{} _:
      +k = bash.fdk(inw, wq, cur)
      +wk = be.kind(False{}, inw, cur, acc, x)
      bash.go(r, LexMode.Un{}, False{}, False{}, "", bash.gt(k, cur, be.acc.k(wk, cur, acc), acc, True{}), ok && Bool.not(Nat.is_eq(k, 2n)), home, be.x.k(wk, cur, acc, x))
    case SCon{Chr{62}, SCon{Chr{38}, +r}} LexMode.Un{} _:
      +k = bash.fdk(inw, wq, cur)
      +n = bash.dup(r)
      +f = lx.is_zero(k) && Bool.not(lx.nz(n))
      +wk = be.kind(False{}, inw, cur, acc, x)
      bash.go(r, bash.dup_mode(f, n), False{}, False{}, "", bash.dup_out(f, bash.dup_acc(k, be.acc.k(wk, cur, acc), acc)), ok && Bool.not(Nat.is_eq(k, 2n)) && (lx.nz(n) || f), home, be.x.k(wk, cur, acc, x))
    case SCon{Chr{62}, SCon{Chr{40}, r}} LexMode.Un{} _:
      None{}
    case SCon{Chr{62}, SCon{Chr{124}, r}} LexMode.Un{} _:
      None{}
    case SCon{Chr{62}, r} LexMode.Un{} _:
      +k = bash.fdk(inw, wq, cur)
      +wk = be.kind(False{}, inw, cur, acc, x)
      bash.go(r, LexMode.Un{}, False{}, False{}, "", bash.gt(k, cur, be.acc.k(wk, cur, acc), acc, False{}), ok && Bool.not(Nat.is_eq(k, 2n)), home, be.x.k(wk, cur, acc, x))
    # heredoc: the end word is skipped and the body starts after the line
    case SCon{Chr{60}, SCon{Chr{60}, +r}} LexMode.Un{} _:
      +q = hd.parse(r)
      +k = bash.fdk(inw, wq, cur)
      +wk = be.kind(False{}, inw, cur, acc, x)
      bash.go(r, LexMode.Skip{hd.n(q)}, False{}, False{}, "", be.acc.k(wk, cur, acc), ok && lx.is_zero(k) && bx.hdnone(x), home, bx.hdset(be.x.k(wk, cur, acc, x), q))
    case SCon{Chr{60}, SCon{Chr{40}, r}} LexMode.Un{} _:
      None{}
    case SCon{Chr{60}, SCon{Chr{38}, r}} LexMode.Un{} _:
      None{}
    case SCon{Chr{60}, SCon{Chr{62}, r}} LexMode.Un{} _:
      None{}
    case SCon{Chr{60}, r} LexMode.Un{} _:
      +k = bash.fdk(inw, wq, cur)
      +wk = be.kind(False{}, inw, cur, acc, x)
      bash.go(r, LexMode.Un{}, False{}, False{}, "", T.In{} <> be.acc.k(wk, cur, acc), ok && lx.is_zero(k), home, be.x.k(wk, cur, acc, x))
    # refused: subshells, command substitution, braces
    case SCon{Chr{40}, r} LexMode.Un{} _:
      None{}
    case SCon{Chr{41}, r} LexMode.Un{} _:
      None{}
    case SCon{Chr{96}, r} LexMode.Un{} _:
      None{}
    case SCon{Chr{123}, r} LexMode.Un{} _:
      None{}
    case SCon{Chr{125}, r} LexMode.Un{} _:
      None{}
    # $NAME and ${NAME} of a known variable (or HOME, USERPROFILE): its value,
    # which bash must not split or glob
    case SCon{Chr{36}, +r} LexMode.Un{} _:
      +n = var.len(r)
      +v = var.val(bx.env(x), home, r)
      bash.go(r, LexMode.Skip{n}, True{}, True{}, var.ins(v, cur), acc, ok && var.bok(v, n, r, cur, home), home, bx.sub(x, v, False{}))
    # ~ and every other character join the word
    case SCon{Chr{126}, +r} LexMode.Un{} _:
      +tv = asg.tilde(x, cur, r, home)
      bash.go(r, LexMode.Un{}, True{}, wq, lx.pick_s(tv, String.append(String.reverse(var.hpos(home)), cur), SCon{Chr{126}, cur}), acc, ok && (tv || lx.utilde(inw, cur)), home, bx.uchar(x, Chr{126}, inw, cur))
    case SCon{+c, r} LexMode.Un{} _:
      bash.go(r, LexMode.Un{}, True{}, wq, SCon{c, cur}, acc, ok, home, bx.uchar(x, c, inw, cur))

# Lex.bash(home, s): the tokens of bash text s and its quoted-wildcard words,
# or None (unknown)
def bash(+home: String, +s: String) -> Maybe<&2, LexOut>:
  bash.go(s, LexMode.Un{}, False{}, False{}, "", [], lx.clean(s, False{}, True{}), home, bx.new())

# the tokens alone
def toks(m: Maybe<&2, LexOut>) -> Maybe<&2, List<&2, T.Tok>>:
  match m:
    case Some{LexOut.Mk{ts, l}}:
      Some{ts}
    case None{}:
      None{}

# ---- PowerShell helpers -----------------------------------------------------------

# after $HOME or $env:USERPROFILE: \ or / or a word end
def pwsh.follow(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{Chr{92}, t}:
      True{}
    case SCon{Chr{47}, t}:
      True{}
    case SCon{c, t}:
      lx.term(c)

def pwsh.name(+r: String, name: String, n: Nat) -> Bool:
  String.starts_with(r, name) && pwsh.follow(String.drop(r, n))

# r is the text after an unquoted $ at the start of a word: the length of
# HOME or env:USERPROFILE when one is there and properly followed, else 0n
def pwsh.home(+r: String) -> Nat:
  +a = lx.pick_n(pwsh.name(r, "env:USERPROFILE", 15n), 15n, 0n)
  lx.pick_n(pwsh.name(r, "HOME", 4n), 4n, a)

# $null as a whole word, right after > or >> (the model reads it as no file)
def pwsh.null(+r: String, acc: List<&2, T.Tok>) -> Bool:
  String.starts_with(r, "null") && lx.tend(String.drop(r, 4n)) && lx.after_redir(acc)

# the exact word -Confirm:$false: cur is "-Confirm:" reversed, r follows the $
def pwsh.conf(+cur: String, +r: String) -> Nat:
  lx.pick_n(String.eq(cur, ":mrifnoC-") && String.starts_with(r, "false") && lx.tend(String.drop(r, 5n)), 5n, 0n)

# what the word before > >> >&1 is: 0n an ordinary word (or none); 1n "1";
# 2n "2"; 4n "*" (all streams); 3n refused (another stream number, or a word
# ending in a digit or *)
def pwsh.fdk.last(+c: Char) -> Nat:
  lx.pick_n(Char.is_digit(c) || U32.is_eq(Char.to_u32(c), 42), 3n, 0n)

def pwsh.fdk.one(c: Char) -> Nat:
  match c:
    case Chr{49}:
      1n
    case Chr{50}:
      2n
    case Chr{42}:
      4n
    case _:
      pwsh.fdk.last(c)

def pwsh.fdk.go(cur: String) -> Nat:
  match cur:
    case SNil{}:
      0n
    case SCon{c, SNil{}}:
      pwsh.fdk.one(c)
    case SCon{c, r}:
      pwsh.fdk.last(c)

def pwsh.fdk(inw: Bool, wq: Bool, cur: String) -> Nat:
  match inw wq:
    case True{} False{}:
      pwsh.fdk.go(cur)
    case _ _:
      0n

# the tokens after > or >> (app); k from pwsh.fdk
def pwsh.gt(k: Nat, inw: Bool, cur: String, acc: List<&2, T.Tok>, app: Bool) -> List<&2, T.Tok>:
  match k:
    case 0n:
      lx.rtok(app, 1) <> lx.push(inw, cur, acc)
    case 1n+j:
      match j:
        case 1n:
          lx.rtok(app, 2) <> acc
        case _:
          lx.rtok(app, 1) <> acc

# -EncodedCommand and its short forms (-e, -ec, -enc, ...), lower case
def pwsh.is_enc(+lw: String) -> Bool:
  String.eq(lw, "-ec") || (Nat.is_le(2n, String.length(lw)) && String.starts_with("-encodedcommand", lw))

# Only the first 16 characters are lower-cased (Base String.to_lower is not
# a loop, so a 40,000-character word overflowed the stack; round 3, P9): a
# longer word is neither --% nor a prefix of -encodedcommand either way.
def pwsh.word.ok(+w: String, wq: Bool, cpos: Bool) -> Bool:
  +lw = String.to_lower(String.take(w, 16n))
  Bool.not(String.eq(lw, "--%") || pwsh.is_enc(lw) || (cpos && (wq || String.eq(w, "."))))

# ---- PowerShell comma lists (round 3, P9) ----------------------------------------
# An unquoted , right after a word, with or without spaces after it, makes the
# word a list: Lex.pwsh writes a,b as ONE word with char 1 between the
# elements (char 1 never occurs in a text, since lx.clean refuses control
# characters). Only the path parameters of the file cmdlets read such a word
# (ModelGit lst.*); every other place treats it as not understood. Refused: a
# comma at the start of a word (,a is PowerShell's one-element array), a
# space before the comma (a ,b), an empty element (a,,b  a,''  a,), a list as
# the command name or a redirect target, an element starting with - or @,
# a quoted ~ at the start of an element, and a newline after the comma.

# the word so far (reversed) ends at a comma: the next element starts here
def pwsh.lst.at(inw: Bool, cur: String) -> Bool:
  match inw cur:
    case True{} SCon{Chr{1}, t}:
      True{}
    case _ _:
      False{}

# a space after a comma keeps the word going
def pwsh.lst.acc(at: Bool, inw: Bool, cur: String, acc: List<&2, T.Tok>) -> List<&2, T.Tok>:
  match at:
    case True{}:
      acc
    case False{}:
      lx.push(inw, cur, acc)

# an unquoted character c may start an element: not - and not @
def pwsh.lst.start(c: Char) -> Bool:
  match c:
    case Chr{45}:
      False{}
    case Chr{64}:
      False{}
    case _:
      True{}

def pwsh.lst.cok(c: Char, cur: String) -> Bool:
  match cur:
    case SCon{Chr{1}, t}:
      pwsh.lst.start(c)
    case _:
      True{}

# a quoted character c may start an element: not ~ (the same rule as lx.qok
# at the start of a word)
def pwsh.lst.qok(c: Char, cur: String) -> Bool:
  match cur:
    case SCon{Chr{1}, t}:
      Bool.not(lx.is_tilde(c))
    case _:
      True{}

# the word in progress may end here: not --% (stop-parsing), not
# -EncodedCommand, and as a command name neither . (dot-sourcing) nor a
# quoted string (PowerShell reads that as an expression, not a command)
def pwsh.wok(inw: Bool, wq: Bool, +cur: String, +acc: List<&2, T.Tok>) -> Bool:
  match inw:
    case False{}:
      True{}
    case True{}:
      pwsh.word.ok(String.reverse(cur), wq, lx.cmdpos(acc)) && Bool.not(pwsh.lst.at(True{}, cur))

# a comma may end the element so far: a word is in progress, it is not empty,
# it may end here, it is neither the command name nor a redirect target, and
# it does not start with -
def pwsh.lst.comma(inw: Bool, wq: Bool, +cur: String, +acc: List<&2, T.Tok>) -> Bool:
  match inw:
    case False{}:
      False{}
    case True{}:
      Bool.not(String.is_empty(cur)) && pwsh.wok(True{}, wq, cur, acc) && Bool.not(lx.cmdpos(acc) || lx.after_redir(acc) || String.ends_with(cur, "-"))

# ---- Lex.pwsh ---------------------------------------------------------------------
# A word is either all bare or one quoted string: a quote next to bare text
# (either side) is refused, since PowerShell's joining rules differ by context.

def pwsh.go(s: String, m: LexMode, +inw: Bool, +wq: Bool, +cur: String, +acc: List<&2, T.Tok>, ok: Bool, +home: String) -> Maybe<&2, List<&2, T.Tok>>:
  match s m inw:
    # end of text
    case SNil{} LexMode.Un{} _:
      lx.fin(ok && pwsh.wok(inw, wq, cur, acc), lx.push(inw, cur, acc))
    case SNil{} _ _:
      None{}
    # characters already handled ($HOME, $null, -Confirm:$false)
    case SCon{c, r} LexMode.Skip{n} _:
      match n:
        case 0n:
          pwsh.go(r, LexMode.Un{}, inw, wq, cur, acc, False{}, home)
        case 1n+k:
          match k:
            case 0n:
              pwsh.go(r, LexMode.Un{}, inw, wq, cur, acc, ok, home)
            case _:
              pwsh.go(r, LexMode.Skip{k}, inw, wq, cur, acc, ok, home)
    # PowerShell has no comment mode here (# is refused)
    case SCon{c, r} LexMode.Com{} _:
      None{}
    # '...': literal, '' is one quote
    case SCon{Chr{39}, SCon{Chr{39}, r}} LexMode.Sq{} _:
      pwsh.go(r, LexMode.Sq{}, True{}, True{}, SCon{Chr{39}, cur}, acc, ok, home)
    case SCon{Chr{39}, r} LexMode.Sq{} _:
      pwsh.go(r, LexMode.Un{}, True{}, True{}, cur, acc, ok, home)
    case SCon{+c, r} LexMode.Sq{} _:
      pwsh.go(r, LexMode.Sq{}, True{}, True{}, SCon{c, cur}, acc, ok && lx.qok(c, cur) && pwsh.lst.qok(c, cur), home)
    # "...": only without $ and backtick; "" is one quote
    case SCon{Chr{34}, SCon{Chr{34}, r}} LexMode.Dq{} _:
      pwsh.go(r, LexMode.Dq{}, True{}, True{}, SCon{Chr{34}, cur}, acc, ok, home)
    case SCon{Chr{34}, r} LexMode.Dq{} _:
      pwsh.go(r, LexMode.Un{}, True{}, True{}, cur, acc, ok, home)
    case SCon{Chr{36}, r} LexMode.Dq{} _:
      None{}
    case SCon{Chr{96}, r} LexMode.Dq{} _:
      None{}
    case SCon{+c, r} LexMode.Dq{} _:
      pwsh.go(r, LexMode.Dq{}, True{}, True{}, SCon{c, cur}, acc, ok && lx.qok(c, cur) && pwsh.lst.qok(c, cur), home)
    # unquoted: quotes only at the start of a word (or of a list element)
    case SCon{Chr{39}, r} LexMode.Un{} False{}:
      pwsh.go(r, LexMode.Sq{}, True{}, True{}, cur, acc, ok, home)
    case SCon{Chr{34}, r} LexMode.Un{} False{}:
      pwsh.go(r, LexMode.Dq{}, True{}, True{}, cur, acc, ok, home)
    case SCon{Chr{39}, r} LexMode.Un{} True{}:
      pwsh.go(r, LexMode.Sq{}, True{}, True{}, cur, acc, ok && pwsh.lst.at(True{}, cur), home)
    case SCon{Chr{34}, r} LexMode.Un{} True{}:
      pwsh.go(r, LexMode.Dq{}, True{}, True{}, cur, acc, ok && pwsh.lst.at(True{}, cur), home)
    # unquoted: word ends (a space or tab right after a list comma does not)
    case SCon{Chr{32}, r} LexMode.Un{} _:
      +at = pwsh.lst.at(inw, cur)
      pwsh.go(r, LexMode.Un{}, at, False{}, lx.pick_s(at, cur, ""), pwsh.lst.acc(at, inw, cur, acc), ok && (at || pwsh.wok(inw, wq, cur, acc)), home)
    case SCon{Chr{9}, r} LexMode.Un{} _:
      +at = pwsh.lst.at(inw, cur)
      pwsh.go(r, LexMode.Un{}, at, False{}, lx.pick_s(at, cur, ""), pwsh.lst.acc(at, inw, cur, acc), ok && (at || pwsh.wok(inw, wq, cur, acc)), home)
    case SCon{Chr{10}, r} LexMode.Un{} _:
      pwsh.go(r, LexMode.Un{}, False{}, False{}, "", lx.nl(lx.push(inw, cur, acc)), ok && pwsh.wok(inw, wq, cur, acc), home)
    # operators
    case SCon{Chr{59}, r} LexMode.Un{} _:
      pwsh.go(r, LexMode.Un{}, False{}, False{}, "", T.Seq{} <> lx.push(inw, cur, acc), ok && pwsh.wok(inw, wq, cur, acc), home)
    case SCon{Chr{38}, SCon{Chr{38}, r}} LexMode.Un{} _:
      pwsh.go(r, LexMode.Un{}, False{}, False{}, "", T.And{} <> lx.push(inw, cur, acc), ok && pwsh.wok(inw, wq, cur, acc), home)
    case SCon{Chr{38}, r} LexMode.Un{} _:
      None{}
    case SCon{Chr{124}, SCon{Chr{124}, r}} LexMode.Un{} _:
      pwsh.go(r, LexMode.Un{}, False{}, False{}, "", T.Or{} <> lx.push(inw, cur, acc), ok && pwsh.wok(inw, wq, cur, acc), home)
    case SCon{Chr{124}, r} LexMode.Un{} _:
      pwsh.go(r, LexMode.Un{}, False{}, False{}, "", T.Pipe{} <> lx.push(inw, cur, acc), ok && pwsh.wok(inw, wq, cur, acc), home)
    # redirects: 2>&1 and *>&1 are dropped; > >> 1> 2> *> and their >> forms
    case SCon{Chr{62}, SCon{Chr{38}, SCon{Chr{49}, +r}}} LexMode.Un{} _:
      +k = pwsh.fdk(inw, wq, cur)
      pwsh.go(r, LexMode.Un{}, False{}, False{}, "", acc, ok && (Nat.is_eq(k, 2n) || Nat.is_eq(k, 4n)) && lx.tend(r), home)
    case SCon{Chr{62}, SCon{Chr{38}, r}} LexMode.Un{} _:
      None{}
    case SCon{Chr{62}, SCon{Chr{62}, r}} LexMode.Un{} _:
      +k = pwsh.fdk(inw, wq, cur)
      pwsh.go(r, LexMode.Un{}, False{}, False{}, "", pwsh.gt(k, inw, cur, acc, True{}), ok && Bool.not(Nat.is_eq(k, 3n)) && pwsh.wok(inw, wq, cur, acc), home)
    case SCon{Chr{62}, r} LexMode.Un{} _:
      +k = pwsh.fdk(inw, wq, cur)
      pwsh.go(r, LexMode.Un{}, False{}, False{}, "", pwsh.gt(k, inw, cur, acc, False{}), ok && Bool.not(Nat.is_eq(k, 3n)) && pwsh.wok(inw, wq, cur, acc), home)
    # a comma list (round 3, P9): the word goes on with char 1 and a new element
    case SCon{Chr{44}, r} LexMode.Un{} _:
      pwsh.go(r, LexMode.Un{}, True{}, False{}, SCon{Chr{1}, cur}, acc, ok && pwsh.lst.comma(inw, wq, cur, acc), home)
    # refused: < (reserved), subexpressions, script blocks, comments, backtick
    case SCon{Chr{60}, r} LexMode.Un{} _:
      None{}
    case SCon{Chr{40}, r} LexMode.Un{} _:
      None{}
    case SCon{Chr{41}, r} LexMode.Un{} _:
      None{}
    case SCon{Chr{123}, r} LexMode.Un{} _:
      None{}
    case SCon{Chr{125}, r} LexMode.Un{} _:
      None{}
    case SCon{Chr{35}, r} LexMode.Un{} _:
      None{}
    case SCon{Chr{96}, r} LexMode.Un{} _:
      None{}
    # @ at the start of a word: @( @{ and splatting
    case SCon{Chr{64}, r} LexMode.Un{} False{}:
      None{}
    # $: $HOME, $env:USERPROFILE, or $null after a redirect, at the start of a word
    case SCon{Chr{36}, +r} LexMode.Un{} False{}:
      +isnull = pwsh.null(r, acc)
      +n = lx.pick_n(isnull, 4n, pwsh.home(r))
      pwsh.go(r, LexMode.Skip{n}, True{}, False{}, lx.pick_s(isnull, "llun$", String.reverse(home)), acc, ok && lx.nz(n) && Bool.not(String.is_empty(home)), home)
    # inside a word: only -Confirm:$false
    case SCon{Chr{36}, +r} LexMode.Un{} True{}:
      +n = pwsh.conf(cur, r)
      pwsh.go(r, LexMode.Skip{n}, True{}, wq, "eslaf$" ++ cur, acc, ok && lx.nz(n) && Bool.not(wq), home)
    # ~ and every other character join a bare word
    case SCon{Chr{126}, r} LexMode.Un{} _:
      pwsh.go(r, LexMode.Un{}, True{}, wq, SCon{Chr{126}, cur}, acc, ok && lx.utilde(inw, cur) && Bool.not(wq), home)
    case SCon{+c, r} LexMode.Un{} _:
      pwsh.go(r, LexMode.Un{}, True{}, wq, SCon{c, cur}, acc, ok && Bool.not(wq) && pwsh.lst.cok(c, cur), home)
    # bash-only modes (never reached here)
    case SCon{c, r} _ _:
      None{}

# Lex.pwsh(home, s): the tokens of PowerShell text s, or None (unknown)
def pwsh(+home: String, +s: String) -> Maybe<&2, List<&2, T.Tok>>:
  pwsh.go(s, LexMode.Un{}, False{}, False{}, "", [], lx.clean(s, True{}, True{}), home)
