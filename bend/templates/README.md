# bend-guard templates: project rules, laws and proofs

`tools/gen.mjs` fills these text templates from a draft's `sort.json` and the
approved projects, and writes `project/Rules.bend`, `project/LAWS.bend` and
`project/PROOF.bend` (plan Tasks 2.5 and 3.1). `bend/fixtures/bend2_test/`
holds the files these templates give for `C:\Users\user\bend2_test` (its
`rules.json` is the draft `sort.json`), filled in by hand; the generator must
reproduce them byte for byte.

Each project law is one instance of a generic law in `bend/laws/rules/LAWS.bend`
(proven once for every table), so a project proof is a single call. The
project folder sits next to `core/` and `laws/` in a staged build
(`project/X.bend` imports `../core/...` and `../laws/rules/...`).

## Files

| File | What it is | Placeholders |
|---|---|---|
| `Rules.bend` | the table, `def table() -> List<&2, T.Project>` | `{{PROJECTS}}` |
| `LAWS.bend` | project laws: header and imports | `{{ROOT_SHOW}}`, `{{LAWS}}` |
| `PROOF.bend` | project proofs: header and imports | `{{PROOFS}}` |
| `law/<kind>.bend` | one law: a plain-English comment line, then the law | see below |
| `proof/<kind>.bend` | the proof of that law | see below |

Kinds (`law/` and `proof/` have the same file names):

| sort.json rule | Template files | Law name `{{LAW}}` | Generic law used |
|---|---|---|---|
| `{"kind": "NoChange", "rel": R}` | `NoChange` | `<n>_protected` | `rule_nochange_denies` |
| `{"kind": "NoReadOrChange", "rel": R}` | `NoReadOrChange-change`, then `NoReadOrChange-read` | `<n>_protected`, `<n>_unreadable` | `rule_noread_change_denies`, `rule_noread_read_denies` |
| `{"kind": "TreeDeleteOnlyUnder", "rel": R}` | `TreeDeleteOnlyUnder` | `tree_delete_only_<n>` | `rule_tree_delete_denies` (one per project: Guard applies each rule on its own, so two would each deny what the other allows; gen.mjs refuses a second) |
| `{"kind": "NoForcePush"}` | `NoForcePush` | `force_push_denied` | `rule_force_push_denies` |
| `{"kind": "NoPushTo", "branch": B}` | `NoPushTo` | `push_<n>_denied` (n from B) | `rule_push_to_denies` |
| `{"kind": "TrustScript", "name": N}` | none (it only allows; no law) | | |
| every project, once, last | `reads_allowed` | `reads_allowed` | `read_allowed` |

`<n>`: R (or B) lower-cased, every run of characters outside `a-z0-9` turned
into one `_`, `_` trimmed from both ends; if that leaves nothing or starts with
a digit, prefix `x`. If a name is already taken in this LAWS.bend (two rules
give the same name, or `reads_allowed`), add `_2`, `_3`, ... in order.
Examples: `specs` gives `specs_protected`; `.env` gives `env_protected` and
`env_unreadable`; `tmp` gives `tree_delete_only_tmp`; `main` gives
`push_main_denied`.

## Placeholders

All placeholders are `{{NAME}}` with `NAME` in `[A-Z0-9_]`; replace every
occurrence, and fail if any `{{` remains afterwards. Values never contain `"`
or `\`: gen.mjs has already refused a `rel` that is not plain lower-case
relative segments (`[a-z0-9._-]`, separated by `/`, no `.` or `..` segment,
no leading `/`) and a `branch` or script name outside `[A-Za-z0-9._/-]+`.

| Placeholder | Value | Bend2_test example |
|---|---|---|
| `{{ROOT}}` | the project root as a Bend literal: `T.Path{"<drive>", ["<seg>", ...]}`, segments of the normalised root (lower case, as `Path.norm` gives) separated by `, ` | `T.Path{"c", ["users", "user", "bend2_test"]}` |
| `{{ROOT_SHOW}}` | the root as `Path.show` prints it | `c:/users/user/bend2_test` |
| `{{LINE}}` | the BEND_RULES.md line number of the rule | `1` |
| `{{REL}}` | the rule's `rel` | `specs` |
| `{{BRANCH}}` | the NoPushTo rule's `branch` | `main` |
| `{{LAW}}` | the law name (table above) | `specs_protected` |
| `{{PRE}}` | the table's projects before this project, as a one-line list of project literals | `[]` |
| `{{POST}}` | the table's projects after this project, the same way | `[]` |
| `{{RS1}}` | this project's rules before this rule, as a one-line list of rule literals | `[T.NoChange{"specs"}]` |
| `{{RS2}}` | this project's rules after this rule, the same way | `[T.NoReadOrChange{"secrets"}, T.NoChange{"build"}]` |
| `{{PROJECTS}}` | every project of the table, rendered as below, joined by `,` and a newline | |
| `{{LAWS}}` | the filled `law/*.bend` snippets, joined by one empty line | |
| `{{PROOFS}}` | the filled `proof/*.bend` snippets, in the same order, joined by one empty line | |

Literals:
- Rule: `T.NoChange{"R"}`, `T.NoReadOrChange{"R"}`, `T.TreeDeleteOnlyUnder{"R"}`,
  `T.NoForcePush{}`, `T.NoPushTo{"B"}`, `T.TrustScript{"N"}`.
- Project (in `{{PRE}}`/`{{POST}}`): `T.Project{<ROOT>, <rules as a one-line list>}`.
- One-line list: `[]` when empty, else `[` + items joined by `, ` + `]`.
- A project in `{{PROJECTS}}`: with rules,
  ```
      T.Project{<ROOT>, [
        <rule>,
        <rule>
      ]}
  ```
  (4 spaces before `T.Project`, 6 before each rule, 4 before `]}`); with no
  rules, `    T.Project{<ROOT>, []}`.

Order:
- The table holds every approved project plus the draft's project, sorted by
  `{{ROOT_SHOW}}`; a re-approved project replaces its old entry. `{{PRE}}` and
  `{{POST}}` must be cut from that same order, or the proofs do not check.
- A project's rules are its hard lines' `rules` in BEND_RULES.md line order,
  and within a line in the order of its `rules` array (TrustScript rules
  included, they only allow). `{{RS1}}` and `{{RS2}}` are cut from that list.
- Laws and proofs follow the same order (a NoReadOrChange rule gives its
  `-change` law, then its `-read` law), then `reads_allowed`.
- The generated LAWS.bend and PROOF.bend cover only the draft's project. Laws
  of other approved projects were proven when they were approved and still hold
  for the bigger table, since every generic law holds for any `pre` and `post`.

The comment line above each law is what the approve tool shows the user; copy it
from LAWS.bend (the line starting `# Rule`, or for `reads_allowed` the line
above it), without the leading `# `.

## What each law says, and limits

- Every Deny law assumes `Call.Ctx.log_only(x) == False`: project rules are not
  enforced in log-only mode (D8). The core self-protection laws hold in
  log-only mode too.
- The meaning `m` is free, so the laws hold whatever the translator says the
  call does. For an Unknown meaning they cover the parts that were understood.
- `<n>_unreadable` covers a `Read` action. A `ReadTree` under the zone is also
  denied by the code, but a `ReadTree` of a folder that strictly contains the
  zone is asked about (D4), so the law states only the plain read.
- `tree_delete_only_<n>` covers a `DeleteTree` whose path overlaps the root
  (inside it, or containing it). The code also denies one run from a folder in
  the project; the law does not need to say so.
- `force_push_denied` and `push_<n>_denied` cover a `GitPush` whose folder is
  under the root. The code also refuses an unknown folder (the sentinel).
- `reads_allowed` keeps hypotheses `h3` (not a protected path) and `h5`
  (outside log-only mode) as written in plan Task 2.5, though the proof does
  not need them.
- Laws are stated over `Guard.run_m(Rules.table(), x, m, t, a)`, which is
  `Policy.run_m(x, m, t, a)` by definition; `base/Policy.bend` and its template
  tie the two with a one-line law.
