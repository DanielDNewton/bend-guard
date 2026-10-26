# bend-guard: Bend 2 notes (binding for every Bend file in this plugin)

Written by the foundation agent on 2026-10-25, from runs of Bend 2.0.39 in WSL
(`/opt/bend-2.0.39/bin/bend`, sha256 `2ec160fa…45cd`). Every example below was
copied from a file that checked (`ALL PROOFS CHECK`) or ran as shown. Where this
file and `docs/plan.md` disagree on Bend spelling, this file wins.

References: `bend guide`, `bend base <Name>` (inside WSL), and a clone of the Bend 2 source repository
(`guide\GUIDE.md`, `bend2\base.bend`, `demos\proof_*`, `tests\{import,proof,check,base}`).

## 1. Building and checking

All scripts run inside WSL as root through a login shell (`bash -l`), which puts
`bend` on PATH and sets `BEND_NO_TELEMETRY=1`.

| Step | Command (WSL paths) |
|---|---|
| stage | `bash -l /mnt/c/Users/user/.claude/local-plugins/bend-guard/tools/stage.sh <name> /mnt/c/Users/user/.claude/local-plugins/bend-guard/bend [<project-dir>]` → prints `/root/bg-build/<name>` |
| check | `bash -l .../tools/check.sh /root/bg-build/<name>` → last line `BEND-GUARD CHECK OK` (exit 0) or `BEND-GUARD CHECK FAILED` (exit 1) |
| compile | `bash -l .../tools/compile.sh /root/bg-build/<name> base/Policy.bend /root/bg-build/<name>/policy.mjs` → `sha256 <hex>` then `compiled <out> (<n> bytes)` |

From Git Bash: `MSYS_NO_PATHCONV=1 wsl -d Ubuntu-24.04 -u root --exec bash -l /mnt/c/.../tools/check.sh /root/bg-build/<name>`.
From node: `tools/wsl.mjs` (`runWsl(script, args, {timeoutMs})`, `bendSha256()`).

**Use `wsl.exe ... --exec`, not `--`.** After `--`, wsl.exe hands the words to the
distro's default shell, which expanded `$HOME` and ate a `\n` in a test
(`printf '[%s]\n' '$HOME'` printed `[/root]n`). With `--exec` the arguments arrive
unchanged.

While other agents are still writing, stage your own build and delete the
files outside your import closure before `check.sh` (it scans every `.bend` in
the build folder).

### What bend prints (exit code is 0 in every case; read the output)

| Situation | Output |
|---|---|
| all good, `bend X.bend` or `--check-only` | `ALL PROOFS CHECK` then `Use --verdict for mathematical validity.` |
| all good, `--verdict` | `ALL PROOFS CHECK` (one line) |
| file with a `main` returning a value, `bend X.bend` | only the printed value (e.g. `["git", "push"]`); use `--check-only` to check |
| a false proof | `SOME PROOFS FAIL` / `Error:` / `- expected : ...` / `- observed : ...` / `Location: <def>` |
| a law with no def (open claim) | `SOME PROOFS FAIL` / `Error: 1 TODO found.` / `The code is incomplete, and not a valid proof yet.` |
| a `?TODO` hole | same as a law with no def (`Error: 1 TODO found.`) |
| any `@unsafe def` in the closure | `SOME PROOFS FAIL` / `Error: 2 defs rely on unsafe or foreign code:` / `defs that depend on @unsafe: loop, bogus` (it names the unsafe def and every def using it, in all three modes) |
| `-o out.mjs` success | nothing; the file is written |
| `-o out.mjs` on a failing file | `SOME PROOFS FAIL` ...; no file is written |

`--check-only` checks the file and its imports and runs nothing; on success it
prints exactly the two lines above. `--verdict` re-checks with the Lean-proven
kernel; on the verdict laws it takes well under a second.

### Forms that would bypass proofs (check.sh refuses all of them)

Bend has no `axiom`/`postulate`/`assume`/`admit`/`sorry` keyword. The bypasses are:
- `@unsafe def` and its sugar `def f?(..)` (no termination check);
- a hole `?name` / `?TODO`;
- a `law` with no def: an *axiom* (an "open claim"). Bend counts it as a TODO
  and refuses any live use of it ("an unfilled law is a dead claim");
- a foreign body: a def whose body is an indented `import "./x.js"` (effects);
- hub imports `import 0x<hash>/main.bend as P` / `import name@ver/...` (bend
  fetches them from the network at check time).

check.sh strips strings, char literals and `#` comments, then refuses any `@unsafe`,
any `?`, any indented `import`, and any top-level import other than `import Base`
or `import ./x.bend as X` / `import ../x.bend as X` that resolves inside the build
folder. It stops before running bend when it finds one. Open laws and holes are
also caught by bend itself (`TODO found`).

## 2. Files, imports and names

### Imports (checked)

- `import Base` first, then local imports. **Every local import needs `as <Alias>`**
  (`import ./Types.bend` alone is refused). Paths are plain names: letters,
  digits, `_` and `-`; `./`, subfolders and `../` all work. A file name with an
  extra dot (`LAWS.Nat.bend`) is refused.
- Everything from an imported file is qualified by the alias: types, constructors
  and defs. `T.Verdict`, `T.Allow{}`, `Verdict.max(x, y)`. A bare `Allow{}` or
  `Verdict` from another file is "unknown".
- The same file imported from several places is loaded once (by real path), so
  `T.Verdict` is the same type everywhere.
- **Defs must be written above their first use** in the same file (calling a def
  defined lower down fails with "an unfilled law is a dead claim"). No mutual
  recursion. Types may refer to each other in any order.
- Inside its own file a def is called by the exact name it was defined with.

```python
# core/Verdict.bend: sibling import
import Base
import ./Types.bend as T

# core/sub/Leaf.bend: parent import from a subfolder
import Base
import ../Types.bend as T

# laws/verdict/LAWS.bend: laws import core with ../../
import Base
import ../../core/Types.bend as T
import ../../core/Verdict.bend as Verdict

# laws/verdict/PROOF.bend: must import its sibling LAWS.bend
import Base
import ../../core/Types.bend as T
import ../../core/Verdict.bend as Verdict
import ./LAWS.bend as Laws

# base/Policy.bend (and project/*.bend): one level up
import ../core/Types.bend as T
```

### The naming convention (ONE convention, use it everywhere)

1. **Types.bend is always imported as `T`.** Types and constructors are written
   `T.Path`, `T.Call`, `T.Allow{}`, `T.Known{[T.Read{p}]}`, `T.Step.Done{v}`.
2. **Every other file is imported with its basename as alias:**
   `import ./Path.bend as Path`, `import ../../core/Guard.bend as Guard`.
3. A plan name `F.f` that lives in file `F.bend` is defined **bare** in that file
   (`def norm(...)` in Path.bend) and written `F.f` everywhere else (`Path.norm`),
   which is exactly the plan's spelling.
4. A plan name `A.f` that lives in a file `F.bend` with `A ≠ F` keeps its full
   name as the def (`def Seg.eq(...)` in Path.bend) and is written `F.A.f`
   elsewhere (`Path.Seg.eq`). Checked: a def `Dot.twice` in Dot.bend is reached as
   `Dot.Dot.twice`, not `Dot.twice`.
5. **Exception, the entry `base/Policy.bend`:** its plan names keep the `Policy.`
   prefix (`def Policy.decide(c: T.Call) -> T.Step:`), because defs written in the
   entry file keep their written name as JS export key, and the host calls
   `"Policy.decide"`. A file importing Policy.bend (alias `Policy`) writes
   `Policy.Policy.run_m(...)`.
6. Helpers live next to their def with a dotted suffix: `norm.go`, `pick.if`,
   `sorted_ins.fin`. A bare def must not reuse a Base name (`bend base <name>`).
7. A proof of `law x` in `LAWS.bend` is `def Laws.x(...)` in `PROOF.bend`.
   Defining any *other* name starting with `Laws.` is refused ("Laws is an
   import's alias").

Constructor names are **global across all files and Base**: a type may not
declare a constructor Base already has. Base owns: ALeaf ANode App Chr Close Con
Done EQ Emit Exit F32 Fail False GT Halt Inl Inr Key LT Look MLeaf MNode MTip
Mouse Move Nil None Pix Qua Ready SCon SNil Scroll Some Succ Text True Tuple U32
Unit WCon WNil Wait Zero. A dotted constructor name is allowed and avoids the
clash (`Step.Done{v}`); Base *def* names such as `Word` and `Or` do not clash
(`T.Word{"x"}`, `T.Or{}` work).

### Names table (plan "Shared interfaces" → Bend spelling at a call site)

| Plan | File | Defined as | Written elsewhere as |
|---|---|---|---|
| types `Path`, `Action`, `Meaning`, `Shell`, `Tok`, `Redir`, `Simple`, `Arg`, `Stage`, `Call`, `Ctx`, `Rule`, `Project`, `Verdict`, `ClefQ`, `ClefAnswer`, `Step` | core/Types.bend | `type X is Data:` | `T.X` |
| every constructor, e.g. `Read{p}`, `Known{as}`, `Deny{r}`, `AtCall{a, c}` | core/Types.bend | same | `T.Read{p}`, `T.Known{as}`, `T.Deny{r}`, `T.AtCall{a, c}` |
| `Tok`'s `App{fd}` | core/Types.bend | `Tok.App{fd: U32}` | `T.Tok.App{fd}` (JS tag `"Tok.App"`) |
| `Step`'s `Done{v}` | core/Types.bend | `Step.Done{v: Verdict}` | `T.Step.Done{v}` (JS tag `"Step.Done"`) |
| `Lex.bash`, `Lex.pwsh` (round 2: `Lex.bash` gives `Maybe<&2, Lex.LexOut>`, tokens plus quoted-wildcard words; `Lex.toks` takes the tokens) | core/Lex.bend | `bash`, `pwsh` | `Lex.bash`, `Lex.pwsh` |
| `Cmd.split`, `Cmd.parts` (round 2: each `Cmd.Part.Mk{s, aa}`, aa = follows &&) | core/Cmd.bend | `split`, `parts` | `Cmd.split`, `Cmd.parts` |
| `Path.norm`, `Path.under`, `Path.overlaps`, `Path.child`, `Path.is_sentinel`, `Path.show`, `Path.clean` | core/Path.bend | `norm`, `under`, `overlaps`, `child`, `is_sentinel`, `show`, `clean` | `Path.norm`, … |
| `Seg.eq` | core/Path.bend | `Seg.eq` | `Path.Seg.eq` |
| `Meaning.is_unknown`, `Meaning.actions`, `Meaning.changes`, `Meaning.reads`, `Meaning.paths` | core/Meaning.bend | `is_unknown`, `actions`, `changes`, `reads`, `paths` | `Meaning.is_unknown`, … |
| `Model.command`, `Model.simple`, `Model.shell`, `Model.next_cwds` (round 2, P2: `Model.shell(sh, cwds, root, home, text)` and `Model.simple(sh, cwds, root, home, lit, s)` take the project folder) | core/ModelShell.bend | `Model.command`, `Model.simple`, `Model.shell`, `Model.next_cwds` | `ModelShell.Model.command`, … |
| round 2, P2: wildcard and named-path hits added to an Unknown (`glob.with(m, sh, k, cwds, home, raws)`, `named.with(m, texts, cwds, root, home)`, `named.unknown(m, words, redirs, cwds, root, home)`, `guard_names()`, `glob.match(pat, name)`) | core/Model.bend | bare | `Model.glob.with`, `MH.named.with`, … |
| `Model.tool`, `Model.inert_tools` | core/ModelTools.bend | `Model.tool`, `Model.inert_tools` (zero-argument) | `ModelTools.Model.tool(c)`, `ModelTools.Model.inert_tools()` |
| Model helpers (agent 1), file and git models | core/Model.bend, ModelFiles.bend, ModelGit.bend | the agent's own names, bare | `Model.x`, `ModelFiles.x`, `ModelGit.x` |
| `Call.ctx` | core/Call.bend | `ctx` | `Call.ctx` |
| `Ctx.root`, `Ctx.home`, `Ctx.dan_said_yes`, `Ctx.log_only` | core/Call.bend | `Ctx.root`, `Ctx.home`, `Ctx.dan_said_yes`, `Ctx.log_only` | `Call.Ctx.root`, `Call.Ctx.dan_said_yes`, … |
| `Protect.covers`, `Protect.key_file` | core/Protect.bend | `covers`, `key_file` | `Protect.covers`, `Protect.key_file` |
| `Guard.in_rule_zone`, `Guard.no_rule_names`, `Guard.no_link`, `Guard.can_ask`, `Guard.self_hit`, `Guard.rule_verdict`, `Guard.decide_m`, `Guard.combine`, `Guard.finish`, `Guard.run_m`, `Guard.run_m_without_clef`, `Guard.clef_text` | core/Guard.bend | bare (`in_rule_zone`, …, `clef_text`) | `Guard.run_m`, … |
| round 3, P3: `noread.hit(table, x, t)` (an Unknown shell call names a NoReadOrChange zone), `noread_msg`, the scanner `nr.*` and its local type `NrZ` (`NrZ.Mk{zone, sps}`) | core/Guard.bend | bare | `Guard.noread.hit`, … |
| `Verdict.rank`, `Verdict.max`, `Verdict.is_allow`, `Verdict.is_ask`, `Verdict.is_deny` | core/Verdict.bend | `rank`, `max`, `is_allow`, `is_ask`, `is_deny` (built) | `Verdict.rank`, `Verdict.max`, … |
| `Rules.table` | base/Rules.bend (generated) | `table` (zero-argument) | `Rules.table()` |
| `Policy.decide`, `Policy.run`, `Policy.run_m`, `Policy.meaning`, `Policy.paths`, `Policy.next_cwds`, `Policy.in_rule_zone` | base/Policy.bend (entry) | `Policy.decide`, … (prefix kept, rule 5) | in Policy.bend `Policy.decide`; from a file importing it `Policy.Policy.run_m` |
| laws `max_ge_left`, … | laws/<group>/LAWS.bend | `law max_ge_left:` | proven by `def Laws.max_ge_left(x, y):` in PROOF.bend |

Plan laws written as `Known{[Read{p}]}` become `T.Known{[T.Read{p}]}`.

## 3. Syntax facts (each checked)

### Types and lists

- Data lists are `List<&2, T>` (copyable). Plan `List<String>` fields are
  `List<&2, String>` in Types.bend. `Maybe<&2, T>` likewise.
- List literals: `["Glob", "Grep", "Read"]`, `[]`, cons `h <> t`, patterns
  `case Nil{}:` / `case h <> t:` (or `case Con{h, t}:`).
- Constructor arguments are positional, in field order: `T.Path{"c", ["users", "user"]}`,
  `T.Known{[T.Read{p}]}`, `T.Path{"?", []}` (all checked; the first one
  evaluated by `main` and printed as
  `../core/Types.Known{[../core/Types.Read{../core/Types.Path{"c", ["users", "user"]}}]}`:
  bend's printer shows the defining file's path; JS tags do not).

```python
# zero-argument def (a constant); call it as inert_tools()
def inert_tools() -> List<&2, String>:
  ["Glob", "Grep", "Read"]
```

### Strings, chars and numbers

- `String` is `SNil{}` / `SCon{head: Char, tail: String}`; `Char` is
  `Chr{code: U32}`. Literals `"s"`, `'a'` (= `Chr{97}`).
- Base: `String.eq(a, b)`, `String.starts_with(s, prefix)`, `String.ends_with`,
  `String.contains`, `String.append(a, b)` (or `a ++ b` anywhere),
  `String.take(s, n: Nat)`, `String.drop(s, n: Nat)`, `String.length`,
  `String.is_empty`, `String.reverse`, `String.join(xs, sep)`, `String.concat`,
  `Char.is_eq`, `Char.to_lower`, `Char.is_digit`, `Char.is_space`.
- A `match` on a String can use **string literal patterns**; a Char is matched by
  its code: `case Chr{36}:` is `'$'`. `case _:` is the fallback.
- **Memory: keep string-literal matches small.** A `match` on more than a handful
  of string literals (worse when the case bodies use the matched name again)
  makes bend's checker hold millions of terms. Measured 2026-10-26: 18 such
  defs in ModelFiles, ModelGit, ModelShell and ModelTools pushed the full
  compile of project/Policy.bend to 18.8 GB and 4 min; written as name tables
  they need 7.5 GB and 21 s, with identical verdicts. The form to use: a
  constructor type for the outcomes, a list `name.tab()` of `Mk{"lit", K.X{}}`
  entries in source order, a tail-recursive `name.go` that compares with
  `String.eq` (first equal entry wins), then `match` on the constructor. See
  `art.act` in ModelTools.bend for the full pattern (or `git.sub` in ModelGit).
- U32 literals `0`, `10`; Nat literals `0n`, `2n`, successor pattern `1n+p`.
  Comparison: `(n < 10 : U32)` (operators need the `: T` annotation) or
  `U32.is_eq(a, b)`, `Nat.is_le(a, b)`, `Nat.is_lt(a, b)`. `==` is only the
  equality *type*.
- `&&`, `||` on Bool and `++` on String work without annotation.

```python
def is_git(s: String) -> Bool:
  match s:
    case "git":
      True{}
    case _:
      False{}

def is_dollar(c: Char) -> Bool:
  match c:
    case Chr{36}:
      True{}
    case _:
      False{}

def small(n: U32) -> Bool:
  (n < 10 : U32)

def both(+s: String, t: String) -> Bool:
  String.eq(s, "x") && (String.starts_with(t, s) || String.is_empty(s))

def cat3(a: String, b: String) -> String:
  a ++ "/" ++ b
```

### Bool, Maybe, matches, helpers, quantities

- There is no `if`: match on `True{}` / `False{}`.
- **No computed match:** `match f(x):` is refused. Pass the value to a helper
  def that matches its parameter (`pick.if` below).
- Multi-scrutinee match: `match x y:` with `case T.Ask{r} T.Deny{s}:`; patterns
  nest (`case SCon{Chr{32}, rest} True{}:`); `_` catches the rest.
- Values are affine: using a variable twice fails with `s (consumed more than
  once)`. Mark the parameter `+s` (Data types only) to reuse it (`both` below
  uses `+s` three times). Per the guide, a pattern field written `+r` is
  reusable, and matching a `+` value hands out `+` fields.
- `Maybe`: `Some{x}` / `None{}`, type `Maybe<&2, T>`.

```python
def pick.if(b: Bool, x: String, y: String) -> String:
  match b:
    case True{}:
      x
    case False{}:
      y

def pick(+s: String) -> String:
  pick.if(String.starts_with(s, "--"), "flag", "word")

def first(xs: List<&2, String>) -> Maybe<&2, String>:
  match xs:
    case Nil{}:
      None{}
    case h <> t:
      Some{h}
```

### Termination: a char-by-char lexer with a state argument

The recursive call must pass a strict sub-part (from a pattern) in the first
argument that changes; arguments before it unchanged, after it free. So put the
shrinking String first, then the state. Anything that does not shrink
structurally needs a `Nat` fuel argument first.

```python
# splits on spaces; inw: inside a word; cur: the word so far, reversed
def words.go(s: String, inw: Bool, cur: String, acc: List<&2, String>) -> List<&2, String>:
  match s inw:
    case SNil{} True{}:
      List.reverse(&2, String, String.reverse(cur) <> acc)
    case SNil{} False{}:
      List.reverse(&2, String, acc)
    case SCon{Chr{32}, rest} True{}:
      words.go(rest, False{}, "", String.reverse(cur) <> acc)
    case SCon{Chr{32}, rest} False{}:
      words.go(rest, False{}, cur, acc)
    case SCon{c, rest} _:
      words.go(rest, True{}, SCon{c, cur}, acc)

def words(s: String) -> List<&2, String>:
  words.go(s, False{}, "", [])
# words("git  push   -f origin") ran to ["git", "push", "-f", "origin"]
```

Base generics take the quantity and type: `List.reverse(&2, String, xs)`,
`List.append(&2, String, xs, ys)`, `List.length(&2, String, xs)`.

## 4. Laws and proofs

- `LAWS.bend` states laws, `PROOF.bend` imports it `as Laws` and proves `law x`
  with `def Laws.x(params)` (untyped params; the law gives the types).
- A law is `for` binders then a claim type. `{a == b : T}` is equality; `{==}`
  proves it when both sides compute to the same term. A Bool fact is stated as
  `{f(x) == True{} : Bool}`.
- Hypotheses are `for h: {... == ... : T}` binders (or `A -> B` claims).
- A match in a proof refines the goal per case; a recursive call is the
  induction hypothesis.
- `%e : P` rewrites with `e : {a == b : T}`: `P` is the current goal with `_`
  where `b` is, and the goal becomes `P` with `a` there. To replace `f(x)` by
  `True{}` using `h : {f(x) == True{} : Bool}`, rewrite with
  `Equal.sym(Bool, f(x), True{}, h)`. Base has `Equal.sym`, `Equal.trans`,
  `Equal.cong`, `Empty.absurd(G, e)`.
- A law can also be a typed def: `def or_true(b: Bool) -> {Bool.or(b, True{}) == True{} : Bool}:`.
- `.fin` helper: when a proof must split on a computed Bool (e.g.
  `String.eq(x, h)`), write a helper that takes it as a parameter `c`, returns
  the hypothesis-to-goal function, and matches `c` (see `elem_app.fin`).
- Absurd branch: turn a clash `{False{} == True{} : Bool}` into `Empty` by a
  rewrite through a discriminator type, then `Empty.absurd(Goal, e)`.
- Base has no `String.eq(s, s) == True{}` lemma; it needs induction through
  `Char.is_eq` → `U32.is_eq` → `Word.cmp(32n, …)` (path agent: see Q5).

Verdict laws (laws/verdict, both checker and kernel pass):

```python
law max_ge_left:
  for x: T.Verdict
  for y: T.Verdict
  {Nat.is_le(Verdict.rank(x), Verdict.rank(Verdict.max(x, y))) == True{} : Bool}

def Laws.max_ge_left(x, y):   # in PROOF.bend; 9 cases, each {==}
  match x y:
    case T.Allow{} T.Allow{}:
      {==}
    case T.Allow{} T.Ask{s}:
      {==}
    # ... all nine pairs
    case T.Deny{r} T.Deny{s}:
      {==}

law deny_is_top:
  for r: String
  for y: T.Verdict
  {Verdict.is_deny(Verdict.max(T.Deny{r}, y)) == True{} : Bool}

def Laws.deny_is_top(r, y):   # max matches Deny{r} first, so it computes
  {==}
```

Proof patterns, all in one file that passed checker and `--verdict`:

```python
def elem(+x: String, xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      Bool.or(String.eq(x, h), elem(x, t))

def or_true(b: Bool) -> {Bool.or(b, True{}) == True{} : Bool}:
  match b:
    case True{}:
      {==}
    case False{}:
      {==}

def BoolT(b: Bool) -> Type:
  match b:
    case True{}:
      Empty
    case False{}:
      Unit

def false_ne_true(e: {False{} == True{} : Bool}) -> Empty:
  %e : BoolT(_)
  Unit{}

law elem_cons:
  for +x: String
  for y: String
  for xs: List<&2, String>
  for h: {elem(x, xs) == True{} : Bool}
  {elem(x, y <> xs) == True{} : Bool}

def elem_cons(x, y, xs, h):
  %Equal.sym(Bool, elem(x, xs), True{}, h) : {Bool.or(String.eq(x, y), _) == True{} : Bool}
  or_true(String.eq(x, y))

def elem_app.fin(c: Bool, +x: String, -t: List<&2, String>, -ys: List<&2, String>,
  rec: {elem(x, t) == True{} : Bool} -> {elem(x, List.append(&2, String, t, ys)) == True{} : Bool})
  -> {Bool.or(c, elem(x, t)) == True{} : Bool} -> {Bool.or(c, elem(x, List.append(&2, String, t, ys))) == True{} : Bool}:
  match c:
    case True{}:
      h => {==}
    case False{}:
      h => rec(h)

law elem_app:
  for +x: String
  for xs: List<&2, String>
  for +ys: List<&2, String>
  for h: {elem(x, xs) == True{} : Bool}
  {elem(x, List.append(&2, String, xs, ys)) == True{} : Bool}

def elem_app(x, xs, ys, h):
  match xs:
    case Nil{}:
      Empty.absurd({elem(x, ys) == True{} : Bool}, false_ne_true(h))
    case a <> t:
      elem_app.fin(String.eq(x, a), x, t, ys, elem_app(x, t, ys), h)
```

(Here the law and its proof sit in one file, so the def is named `elem_app`; in a
LAWS/PROOF pair it is `def Laws.elem_app`.)

## 5. The compiled .mjs

`bend Entry.bend -o out.mjs` writes a self-contained ES module (no imports).
`import M from './out.mjs'` gives the object of functions (with `import * as M`,
it is `M.default`).

**Export keys** (printed by Windows node from a two-file program):

```
[ 'Verdict:rank', 'Verdict:Verdict.twice', 'Verdict:thrice', 'Verdict:done_of',
  'sub/Leaf:allow', 'Policy.rank3', 'mk', 'ask' ]
# and for base/Policy.bend importing ../core/Verdict.bend:
../core/Verdict:rank ../core/Verdict:max ... Policy.stricter
```

- A def written in the **entry file** is keyed by its written name: `def mk` →
  `"mk"`, `def Policy.decide` → `"Policy.decide"`.
- A def from an **imported file** is keyed `<path of that file relative to the
  entry, without .bend>:<def name>`: `"../core/Verdict:max"`. Don't call these
  from JS; export what the host needs from the entry.
- So the host keys are exactly `"Policy.decide"`, `"Policy.run"`,
  `"Policy.meaning"`, `"Policy.next_cwds"`, `"Policy.paths"` as long as
  Policy.bend defines them with that prefix (rule 5).

**Values across the boundary** (all seen in runs):

- `List`: `{$:'Con', head, tail}` / `{$:'Nil'}`; `String`: JS string; `Char`: a
  one-character JS string (`D.is_dollar('$')` → `true`); `Nat`, `U32`: numbers;
  `Bool`: `true`/`false`; `Maybe`: `{$:'Some', value}` / `{$:'None'}`.
- Constructors: `{$:'Allow'}`, `{$:'Ask', reason:'why'}`; the alias is not part
  of the tag. **Dotted constructors keep the dot: `{$:'Step.Done', v: …}`,
  `{$:'Tok.App', fd: 2}`.**
- A zero-argument def is a function of no arguments: `D.mk()`,
  `D.inert_tools()`.
- Calls run synchronously: `D['Policy.rank3']({$:'Deny', reason:'q'})` → `2`;
  `D.words('git  push -f')` → the Con/Nil list. A wrong JS type throws a
  TypeError (e.g. a number where a String is expected).

**Import from a data: URL in node** (ran under Windows node v24):

```js
import { readFileSync } from 'node:fs'
const text = readFileSync(new URL('./fs-feat.mjs', import.meta.url), 'utf8')
const url = 'data:text/javascript;base64,' + Buffer.from(text, 'utf8').toString('base64')
const D = (await import(url)).default
console.log(JSON.stringify(D.first({ $: 'Con', head: 'x', tail: { $: 'Nil' } })))  // {"$":"Some","value":"x"}
```

Error stacks from a data: module quote the whole URL; cut error text short
before logging it.

## 6. Changes from plan.md (and why)

| Plan | Here | Why |
|---|---|---|
| `Tok` constructor `App{fd}` | `Tok.App{fd}`, JS tag `"Tok.App"` | Base declares a constructor `App`; constructor names are global |
| `Step` constructor `Done{v}` | `Step.Done{v}`, JS tag `"Step.Done"` | Base declares `Done`. **The glue must test `x.$ === 'Step.Done'`** (glue.ts `BendStep`, checker.ts `isStep`) |
| `List<String>` etc. in types | `List<&2, String>` etc. | data lists must be copyable (`&2`) |
| `Deny{r}`, `Known{[Read{p}]}` in laws | `T.Deny{r}`, `T.Known{[T.Read{p}]}` | imported constructors are qualified by the alias |
| `Model.tool`, `Ctx.root`, `Seg.eq` | `ModelTools.Model.tool`, `Call.Ctx.root`, `Path.Seg.eq` | names table, rule 4 |
| `Rules.table`, `Model.inert_tools` (zero-argument) | `def table() -> ...`, called `Rules.table()` | zero-argument def syntax |
| plan Task 1.1 `wsl.exe ... --` | `wsl.exe ... --exec` | `--` goes through a shell (see section 1) |

## 7. Path (path agent, 2026-10-25)

Files: `core/Path.bend`, `core/Meaning.bend`, `laws/path/LAWS.bend` + `PROOF.bend`
(checker and `--verdict` pass).

### Q5: segment representation: Strings, compared by Nat codes

Segments stay `String` (Types.bend `Path{drive: String, segs: List<&2, String>}`
is unchanged). `Seg.eq(a, b)` walks both strings and compares each char with
`Nat.is_eq(Seg.code(x), Seg.code(y))`, where `Seg.code(Chr{x}) = U32.to_nat(x)`.
Why: Base `String.eq` goes through `String.order` → `Char.cmp` → `U32.cmp` →
`Word.cmp(32n, …)` with tuple results, so transitivity would mean induction over
32-bit words. `Nat.is_eq` reflexivity, symmetry and transitivity are three short
inductions (PROOF.bend `nat_refl`, `nat_symt`, `nat_trans`), and the string
lemmas follow by induction on the string. `List<Nat>` codes would have changed
Types.bend, `show` and the JS boundary for no proof gain. In the compiled .mjs
`U32.to_nat` and `Nat.is_eq` are native (`char_code`, `cmp_new`), so this is fast
(one `Path.norm` ≈ 0.07 ms under node).

Proof fact: a function that matches `Chr{x}` inside a nested pattern only
reduces when the proof has destructured the char too; hiding the code behind
the helper `Seg.code` lets proofs match `SCon{x, t}` with `x` left abstract.

### Meanings (all `Path.x` from other files)

- `Seg.eq(a, b)` plain equality; `eq(a, b)` = drives `Seg.eq` and same segments.
- `under(p, root)` = `Seg.eq(root.drive, p.drive)` and root's segments are a
  prefix of p's (`prefix(xs, ys)`: xs is a prefix of ys). Purely structural:
  `under(sentinel, sentinel)` is True, a "c" path is never under the sentinel.
- `overlaps(p, q)` = `Bool.or(under(p, q), under(q, p))`.
- `child(p, rel)`: rel lower-cased, split on `/` and `\`, trailing dots and
  spaces dropped from each part, and parts that end up empty (`""`, `.`, `..`,
  `...`) dropped; the parts are appended to p's segments. So a child is always
  clean and under p. The rules generator must refuse a `rel` with `..` (it is
  dropped here, not resolved).
- `show(p)` = `"c:/a/b"` (root: `"c:/"`; sentinel `"?:/"`). `is_sentinel(p)`: drive `"?"`.
- `clean(p)`: no `""`, `"."`, `".."` segment (`clean.segs` over the list).
- `norm(cwd, home, raw) -> Maybe<&2, T.Path>`: cwd and home are absolute
  Windows paths; they go through the same parser (`absolute(s)`), and a raw
  path that needs a cwd or home that is not normalisable gives None.
  Choices beyond plan Task 1.6, all stricter: any `%` gives None (not only
  `%NAME%`); a rooted path without a drive letter is None unless it is `/c`,
  `/c/...` or `/mnt/c/...` (SH-1, 2026-10-26: under Git Bash `/` is Git's
  install folder and /proc, /dev, /tmp, /cygdrive are virtual, so `/` alone,
  `/proc/self/cwd/x`, `/dev/tcp/...`, `/etc/x`, `/d/...` and a PowerShell
  `\x` are all None; mapping /tmp to the user Temp folder is left for later);
  `/mnt` alone or `/mnt/<not c>` is None; a stream suffix is
  only cut from the last part, and a trailing separator after it (`a.md:x/`)
  gives None. The junction check runs on the final segments, before
  `norm.fin`, which re-checks `clean.segs` and returns None otherwise.
- Meaning: `is_unknown`, `actions` (Known's actions or Unknown's known parts),
  `changes(m, p)` (Write/Delete/MakeDir with `Path.eq(p, q)`, or
  WriteTree/DeleteTree/MoveFrom with `Path.under(p, q)`), `reads(m, p)` (Read
  with `Path.eq(p, q)`, ReadTree with `Path.under(p, q)`; ListDir is not a
  read), `paths(m)` (`Path.show` of every action path, GitPush's `dir` too).
  Helpers per action: `changes.one(a, p)`, `reads.one(a, p)`, and the list
  folds `changes.list(xs, p)`, `reads.list(xs, p)` (`Bool.or(one, rest)`).

### Laws (laws/path) and how another proof file uses them

`under_refl`, `under_child`, `under_trans`, `overlaps_sym`, `under_overlaps`
(under(a, b) → overlaps(a, b)), `eq_under` (eq(a, b) → under(a, b)),
`ancestors_comparable` (under(p, a) and under(p, b) → overlaps(a, b)) and
`norm_clean`, proven over the **whole** normaliser (via `norm.fin`).

A law is only filled where its PROOF.bend is loaded too. Checked: a file that
imports only `../path/LAWS.bend` and calls the law fails ("an unfilled law is
a dead claim"); importing both works:

```python
import ../path/LAWS.bend as PathLaws
import ../path/PROOF.bend as PathProof
...
  PathLaws.under_trans(a, b, c, h1, h2)
```

Reusable lemmas in `laws/path/PROOF.bend` (call as `PathProof.x`; hypotheses
are curried arguments, and a `-` parameter is erased):

| Lemma | Type |
|---|---|
| `false_ne_true(e)` | `{False{} == True{}} -> Empty` |
| `and_intro(a, -b, ha, hb)` | `{a == True{}} -> {b == True{}} -> {Bool.and(a, b) == True{}}` |
| `and_l(a, -b, h)` / `and_r(a, -b, h)` | `{Bool.and(a, b) == True{}} -> {a == True{}}` / `{b == True{}}` |
| `or_l(a, -b, h)` / `or_r(a, -b, h)` | `{a == True{}}` / `{b == True{}}` `-> {Bool.or(a, b) == True{}}` |
| `or_comm(a, b)` | `{Bool.or(a, b) == Bool.or(b, a)}` |
| `or_and2(d1, -p1, d2, -p2, h1, h2, h3)` | d1, d2 and `Bool.or(p1, p2)` true → `Bool.or(Bool.and(d1, p1), Bool.and(d2, p2))` true |
| `nat_refl(n)`, `nat_symt(a, b, h)`, `nat_trans(a, b, c, h1, h2)` | on `Nat.is_eq` |
| `seg_refl(s)`, `seg_symt(a, b, h)`, `seg_trans(a, b, c, h1, h2)` | on `Path.Seg.eq` |
| `prefix_refl(xs)`, `prefix_app(xs, +ys)`, `prefix_trans(xs, ys, zs, h1, h2)`, `prefix_comp(xs, ys, zs, h1, h2)`, `eqsegs_prefix(xs, ys, h)` | on `Path.prefix` / `Path.eq.segs` |
| `none_ne_some(-p, e)` | `{None{} == Some{p} : Maybe<&2, T.Path>} -> Empty` |

Proof facts learned here (each checked):
- A hypothesis used twice must be reusable: write the lambda `+h => …`, and in
  a law write `for +h: {…}` (a typeless `+h` def parameter is a parse error).
- Pattern fields used twice: `case SCon{+x, +t}:`, `case +h <> +t:`,
  `case T.Path{+d, +xs}:`, `case Some{+xs}:`.
- In a lemma, give a parameter that is only used in types `-` (erased) so
  that passing it costs nothing (`and_l(a, -b)`).
- An impossible case: `Empty.absurd({goal}, false_ne_true(h))`, writing the
  goal as it stands in that case.
- Several rewrites in a row work: `%h : {Path.clean(unwrap(_)) == True{} : Bool}`
  then `%e : {_ == True{} : Bool}` then `{==}` (see `fin_if`).

## 8. Guard proof map (guard agent, 2026-10-25)

Files: `core/Call.bend`, `core/Protect.bend`, `core/Guard.bend` (checked with
`bend --check-only` through a scratch entry importing Guard, and compiled to
.mjs). Guard imports Types, Verdict, Path, Meaning, Call, Protect and no Model
or Lex file.

### Shape of run_m (every function one match deep)

```
Guard.run_m(table, x, m, t, a)            = run.with(self_hit(table, x, m), table, x, m, t, a)
Guard.run_m_without_clef(table, x, m, t)  = run.nc(self_hit(table, x, m), table, x, m, t)
run.with(sh, table, x, m, t, a) = run.go(sh, table, x, m, after_clef(decide.go(sh, table, x, m, t), a))
run.nc(sh, table, x, m, t)      = run.go(sh, table, x, m, step_base(decide.go(sh, table, x, m, t)))
run.go(sh, table, x, m, v)      = protect(sh, table, x, m, relax(relax.cond(x, m), finish(x, floor(v, m))))
Guard.decide_m(table, x, m, t)  = decide.go(self_hit(table, x, m), table, x, m, t)
decide.go(sh, ..)        = decide.sent(bad(x), sh, ..)       step 1: True -> Done{Deny}
decide.sent False        = decide.self(sh, ..)               step 2: True -> Done{Deny{self_msg}}
decide.self False        = decide.rules(rule_verdict(table, x, m), m, ..)   step 3: Deny{r} -> Done{Deny{r}}
decide.rules Ask/Allow   = decide.meaning(m, v, ..)          Known -> decide.known; Unknown -> decide.noread(noread.hit(table, x, t), why, v, table, x, t)
decide.noread            True -> Done{Deny{noread_msg(table, x, t)}}; False -> decide.unknown(can_ask(x), why, v, x, t)   (round 3, P3)
decide.unknown           False -> Done{Deny}; True -> decide.triage(Bool.and(shell_tool, short(t)), Verdict.max(v, Ask{unknown_msg(why)}), t)
decide.triage / decide.veto.clef put text.cap(t) in a Consult (round 3, P3: clef_text is the whole text; only Clef sees it cut)
noread.hit(table, x, t)  = Bool.and(Call.Ctx.shell_tool(x), nr.some(nr.find(table, x, t)))   (the scan of the command part of t)
decide.known             Allow -> decide.veto(zone.acts(xs, table), shell_tool, t); Ask{r} -> Done{Ask{r}}; Deny{r} -> Done{Deny{r}}
after_clef(Done{v}, a) = v;    after_clef(Consult{q, b, t}, a) = combine(b, q, a)
step_base(Done{v}) = v;        step_base(Consult{q, b, t}) = b
combine(base, q, a) = Verdict.max(base, clef.x(q, a))        (clef.x never sees base)
floor(v, m)        matches v first: Ask, Deny unchanged; Allow -> floor.allow(m) (Known: Allow, Unknown: Ask)
finish(x, v)       = finish.go(Call.Ctx.stage(x), can_ask(x), Call.Ctx.dan_said_yes(x), v)
finish.go(s, ca, dy, v)   matches v first: Allow, Deny unchanged; Ask{r} -> finish.ask(s, ca, dy, r)
finish.ask         AtCheck -> finish.check(ca, r) (True: Ask{r}, False: Deny); AtCall -> finish.call(dy, r) (True: Allow, False: Deny)
relax.cond(x, m)   = Bool.and(Call.Ctx.log_only(x), Bool.and(Bool.not(Meaning.is_unknown(m)), Bool.not(bad(x))))
relax(c, v)        True -> Allow; False -> v
protect(sh, table, x, m, v)   True -> Deny{self_msg(table, x, m)}; False -> v
bad(x)             = Bool.or(Path.is_sentinel(Call.Ctx.root(x)), Path.is_sentinel(Call.Ctx.home(x)))
Guard.can_ask(x)   = Call.Ctx.can_ask(x) = Bool.and(Bool.not(agent), Bool.and(Ctx.is_person(approver), interactive))
Call.Ctx.dan_said_yes(x) = Ctx.said_yes(Ctx.stage(x), Ctx.can_ask(x)); said_yes(AtCall{asked, _}, ca) = Bool.and(asked, ca)
```

Self-protection is applied twice on purpose: in decide (step 2, so the glue
never consults Clef for it) and outermost in run.go (`protect`), so the
self-protection laws never unfold decide. `floor` does the same for unknown
meanings. Both change nothing at run time (decide already gave Deny, or at
least Ask).

Bool folds (each `Nil -> False`, `a <> t -> Bool.or(one(a, ..), list(t, ..))`,
the same shape as `Meaning.changes.list` / `reads.list`, so the bridging
lemmas are plain list inductions):
- `self_hit(table, x, m) = self.list(Meaning.actions(m), table, x)`. `self.one`:
  the six change actions give `Bool.or(Protect.covers(table, x, q), N)` with
  N = `Protect.named_or_dir(q)` (`Protect.named(q)` for MakeDir): settings
  files by name, a separate check so covers stays an overlap test (proofs
  wrap covers_up in `PathProof.or_l`; law `named_settings_denied` uses
  `self_app`, a self hit anywhere in an appended list); Read and ReadTree
  give `Path.overlaps(q, Protect.key_file(Call.Ctx.home(x)))`; others False.
- `Protect.covers(table, x, p) = covers.list(Protect.set(table, x), p)`, with
  `covers.list(q <> t, p) = Bool.or(Path.overlaps(p, q), covers.list(t, p))`.
- `hit.one(a, z)`: Write/Delete/MakeDir give `Path.under(q, z)`;
  WriteTree/DeleteTree/MoveFrom give `Path.overlaps(q, z)`. `hit.list(xs, z)`.
- `read.one`: Read/ReadTree give `Path.under(q, z)`. `above.one`: ReadTree gives
  `Bool.and(Path.under(z, q), Bool.not(Path.under(q, z)))`.

rule_verdict:
- `rule_verdict(table, x, m) = rv.go(table, x, Meaning.actions(m))
  = Verdict.max(table.v(table, x, xs), Verdict.max(builtin.list(xs, table, x), link.list(xs, x)))`
- `table.v(Project{root, rules} <> t, x, xs) = Verdict.max(rules.v(rules, root, x, xs), table.v(t, x, xs))`
- `rules.v(r <> t, root, x, xs) = Verdict.max(rule.v(r, root, x, xs), rules.v(t, root, x, xs))`
- `rule.v(NoChange{rel}) = rule.nochange(Path.child(root, rel), xs) = deny_if(hit.list(xs, z), msg)`
- `rule.v(NoReadOrChange{rel}) = Verdict.max(deny_if(Bool.or(hit.list(xs, z), read.list(xs, z)), m1), ask_if(above.list(xs, z), m2))`
- `rule.v(TreeDeleteOnlyUnder{rel}) = deny_if(tdo.list(xs, root, z, x), msg)`;
  `tdo.one(DeleteTree{q}) = Bool.and(tdo.scope(q, root, x), Bool.not(Path.under(q, z)))`;
  `tdo.scope(q, root, x) = Bool.or(Path.overlaps(q, root), Bool.or(Path.under(Ctx.cwd(x), root), Path.is_sentinel(Ctx.cwd(x))))`
- `rule.v(NoForcePush{}) = deny_if(force.list(xs, root), msg)`;
  `force.one(GitPush{dir, force, ..}) = Bool.and(push.scope(dir, root), force)`
- `rule.v(NoPushTo{b}) = Verdict.max(deny_if(pushto.list(xs, root, b), m1), ask_if(unsure.list(xs, root), m2))`;
  `pushto.one(GitPush{dir, _, _, refs, _}) = Bool.and(push.scope(dir, root), elem(b, refs))`;
  `elem(s, h <> t) = Bool.or(Path.Seg.eq(h, s), elem(s, t))`;
  `push.scope(dir, root) = Bool.or(Path.under(dir, root), Path.is_sentinel(dir))`
- `rule.v(TrustScript{n}) = Allow`; TrustScript is read by `builtin.script`.

### Per law: what to unfold, which lemmas

Common small lemmas (each a case split): `and_false_r(b)`:
`Bool.and(b, False{}) == False{}`; `max_deny_left(a, -b)`: is_deny(a) ->
is_deny(Verdict.max(a, b)) (split a); `max_deny_right(a, b)`: is_deny(b) ->
is_deny(Verdict.max(a, b)) (split a, then b); a `.fin` helper that turns
`is_deny(v) == True` into "v is Deny{r}" where a function matches v
(`decide.rules`).

| Law | Unfolds | Needs |
|---|---|---|
| combine_monotone | `combine` | one line: `VerdictLaws.max_ge_left(base, Guard.clef.x(q, a))` (import laws/verdict LAWS + PROOF) |
| finish_monotone | `finish` -> `finish.go(s, ca, dy, v)` | a lemma over free s, ca, dy: split v1, v2 (9 pairs; h kills the 3 decreasing ones); Ask/Ask: split s, then ca or dy |
| clef_cannot_loosen | `run_m` / `run_m_without_clef` -> `run.go(sh, .., after_clef(S, a))` vs `run.go(sh, .., step_base(S))`, the same S = `decide.go(..)` | (1) rank(step_base(S)) <= rank(after_clef(S, a)): split S; Done: refl (split v); Consult: max_ge_left. (2) run.go is monotone in v: floor (split v, m), finish_monotone, relax (split c), protect (split sh; True gives the same Deny term on both sides) |
| unknown_never_allowed | `run_m` -> `run.with` -> `run.go`; never decide | split m (Known: h1 absurd); split sh (True: Deny); relax.cond becomes `Bool.and(log_only(x), False)`: and_false_r; floor(V, Unknown{..}): split V, giving Ask or Deny; rewrite `Call.Ctx.dan_said_yes(x)` (the third argument in `finish`) with h2; finish.go(s, ca, False, Ask{r}): split s, then ca |
| no_ask_without_person | `run.go`; never decide | rewrite `Guard.can_ask(x)` (the term written in `finish`) with h; lemma: is_ask(finish.go(s, False, dy, v)) == False for all s, dy, v; split relax's c (Allow) and sh (Deny) |
| self_protection | `run_m` -> `run.with(self_hit(..), ..)` -> `protect(True, ..)` = Deny | `changes_hits`: changes.list(xs, p) and covers(table, x, p) give self.list(xs, table, x) (induction on xs). Exact actions (`Path.eq(p, q)`): covers(q) needs eq symmetry (seg_symt plus an eq.segs symmetry induction), eq_under, under_trans, under_overlaps. Tree actions (`under(p, q)`): for each covers.list element P, under(p, P) -> ancestors_comparable(p, q, P); under(P, p) -> under_trans(P, p, q) + under_overlaps. Lift over covers.list by induction. Then rewrite sh to True and `{==}` |
| key_unreadable | same as self_protection | reads.list(xs, K) gives self.list(xs, table, x), K = `Protect.key_file(Call.Ctx.home(x))` (the exact term in self.one). Read: eq(K, q) -> eq_under -> under_overlaps -> overlaps_sym gives overlaps(q, K). ReadTree: under(K, q) -> under_overlaps -> overlaps_sym |
| rule_nochange_denies | `run.with(sh, ..)`: split sh (True: Deny); relax.cond: rewrite h0, giving False; `decide.go(False, ..)`: split `bad(x)` (True: Done{Deny}); then `decide.rules(rule_verdict(..))` through a .fin | RV: is_deny(rule_verdict(pre ++ [Project{root, rs1 ++ [NoChange{rel}] ++ rs2}] ++ post, x, m)): max_deny_left on `rv.go`; induction on pre over `table.v` (max_deny_left at the project, max_deny_right in the step); the same on rs1 over `rules.v`; then `hit.list(xs, child(root, rel))` from changes.list(xs, p) and under(p, z) by induction (exact: eq symmetry + eq_under + under_trans; tree: ancestors_comparable(p, q, z)). Once Deny reaches floor and finish they compute (both match v first) |
| rule NoReadOrChange, changes | as NoChange | `Bool.or(True, _)` and `Verdict.max(Deny{..}, _)` compute |
| rule NoReadOrChange, reads | as NoChange | a `Read{q}` with eq(p, q) and under(p, z) makes read.list True (or_r). A `ReadTree{q}` that contains p only overlaps z: Deny when q is under z, but **Ask (D4)** when q strictly contains z. So state the read half for Read (or ReadTree under z), or as "not Allow" with dan_said_yes False |
| rule TreeDeleteOnlyUnder | as NoChange | state membership structurally (actions(m) = pre ++ [DeleteTree{q}] ++ post) with under(q, root) == True and under(q, child(root, rel)) == False; tdo.scope's `Path.overlaps(q, root)` = Bool.or(under(q, root), ..) rewrites to True |
| rule NoForcePush, NoPushTo | as NoChange | GitPush{dir, True{}, ..} with under(dir, root): push.scope rewrites to True. NoPushTo: refs = r1 ++ [b] ++ r2; elem needs seg_refl(b) (`Path.Seg.eq(h, s)` with h = s = b) |
| reads_allowed | everything computes for `T.Known{[T.Read{p}]}` after these rewrites | self_hit = `Bool.or(Path.overlaps(p, Protect.key_file(Call.Ctx.home(x))), False)` (h4); bad(x) (h0, h0b); for each NoReadOrChange zone z of the concrete table, `Path.under(p, z) == False` (from h6: no_rule_names unfolds to a `Bool.and` chain of `Bool.not(Path.overlaps(p, z))`, and overlaps = Bool.or(under(p, z), under(z, p))); link: `ask_unless(no_link(x, p), ..)` (h7); step 6: `zone.acts([Read{p}], table) = Bool.or(in_rule_zone(table, p), False)` (h2, since Policy.in_rule_zone(p) = Guard.in_rule_zone(Rules.table(), p)); relax.cond (h5). The built-in git and attr zone lists have a concrete spine, and hit.one(Read{p}, z) = False for any z. h3 is not needed |
| named_noread_unknown_denied (round 3, P3) | `run_m` -> `run.go(sh, .., after_clef(decide.go(sh, ..), a))`, sh free | step: split `bad(x)` (True: Done{Deny}), sh (True: Done{Deny}), `rule_verdict` (Deny: Done{Deny}), m (Known: h1 absurd); for Unknown rewrite `Guard.noread.hit(table, x, t)` with h2 (`decide.noread(True, ..)` = Done{Deny}). run.go: split v (Deny); floor and finish compute; `rc_false` for relax; split sh for protect (laws/guard/PROOF.bend `nr_*`) |
| run_is_translator_then_policy | base/Policy.bend | `{==}` |

Proof-relevant facts:
- `self_msg(table, x, m)` matches `m` (round 2, P2: an Unknown meaning gets
  the "not fully understood ... use the Read tool" wording). No law looks at
  the text: every self-protection proof ends on `Deny{self_msg(..)}` as a
  term, which is a Deny whatever the text is.
- Compiled Bend is strict JavaScript: `a && b` and `a || b` evaluate both
  sides, and a call that is not the last thing a def does uses the stack.
  Scanners over a whole command text (round 2, P2: `nm.scan`, `nm.fold`,
  `nm.s83`, `nm.join`) are written as loops (the recursive call last) and
  guard costly checks behind a `match` helper, or a 6,000-character command
  overflows the stack (`RangeError: Maximum call stack size exceeded`).
  Round 2, R2M-3: Base `String.to_lower` and an `a || f(t)` fold are not
  loops either; `has_glob`, `glob.has_sep`, `glob.lower`, `cmd.unlit` and
  `ng.flags` are written as loops, because every word of a command that is
  not understood now reaches them (one word can be 20,000 characters).
- `can_ask` inside `finish` is Guard's own `can_ask(x)`, so the hypothesis
  `{Guard.can_ask(x) == False{} : Bool}` rewrites it as written.
- `Call.Ctx.dan_said_yes(x)` is the third argument of `finish.go` as written.
- `self_hit(table, x, m)` is computed once in run_m and passed as `sh` to both
  decide.go and protect. Prove lemmas over `run.with(sh, ..)` for a free
  `sh: Bool`, then instantiate them with `Guard.self_hit(table, x, m)`.
- `Meaning.changes(m, p) = changes.list(Meaning.actions(m), p)` and `self_hit`
  is `self.list(Meaning.actions(m), ..)`: the same `actions(m)` term, so the
  self laws need no split on m.

## Final round: environment values (2026-10-26)

A value that can reach a later program's environment is never "understood":

- `export NAME=WORD` is no longer read as a local assignment (`asg.pos` gives 0n after an `export` word). The `export` stays a command word, which is not modelled, so the call asks in the main session and is refused in agents.
- `var.name_ok` accepts a name as local only if it is not on the known lists and is either short (1 to 3 characters, not in `var.short_denied`: tz, os, cc, cxx, cpp, ar, as, ld, nm, fc, tmp, pwd, ifs, env, _) or all lower case. Any other name may already be in the environment, where an assignment changes what later programs see. `unset` uses the same rule.
- Everyday local use keeps working: `D="C:/x"; cd "$D" && ls`, `dir=src; ls "$dir"`, `F=a.md; cat "$F"`.
- Regression cases: tests/corpus/final-env.jsonl.
