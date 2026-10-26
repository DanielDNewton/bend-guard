---
description: Draft bend-guard's rules from a project's BEND_RULES.md, check the proofs, then tell the user how to approve
disable-model-invocation: true
argument-hint: "[project folder]"
allowed-tools: Read, Glob, Write(~/.claude/bend-guard-drafts/**), Edit(~/.claude/bend-guard-drafts/**), Bash(node ~/.claude/local-plugins/bend-guard/tools/draft-check.mjs *)
---

# /bend-guard:compile

This is the first half of putting a project under bend-guard. You read the project's `BEND_RULES.md` and sort every numbered line. You write the result as plain data (JSON and text). You never write Bend code. A tool builds the Bend rules and laws from your data, and the machine checks every proof. Then the user approves it themselves, with the `/bend-guard` command.

Below, `~` is your home folder: the one `%USERPROFILE%` names, such as `C:\Users\user`. Give the Write tool its full path.

You write three files, all in `~\.claude\bend-guard-drafts\<slug>\`:

| File | What it holds |
| --- | --- |
| `sort.json` | every numbered line of BEND_RULES.md, sorted |
| `ask.json` | settings for the "ask first" and "before finishing" lines |
| `claude-md.txt` | the rules bend-guard cannot enforce, for the user to paste into CLAUDE.md |

Write nowhere else. Never touch `BEND_RULES.md` or `~\.claude\bend-guard\`. bend-guard would refuse, and only the user's approve tool writes there. Use the Write tool for the three files, not Bash. A shell here-document is a command bend-guard cannot read, so the user would be asked.

## 1. Find the project

- **Project root:** the folder in `$ARGUMENTS`, if there is one. Otherwise the nearest folder at or above the working directory that holds a `BEND_RULES.md`. If there is none, stop and tell the user.
- **Normalised root:** lower case, forward slashes, drive first. `C:\Users\user\bend2_test` becomes `c:/users/user/bend2_test`.
- **Slug:** the normalised root with `:`, `/`, `.` and spaces turned into `-`. `c:/users/user/bend2_test` becomes `c--users-user-bend2_test`, and `c:/users/user/my app` becomes `c--users-user-my-app`.
- If the drafts folder already holds files from an earlier run, Read each one before you replace it. The Write tool refuses to replace a file you have not read.

## 2. Read the rules

Read `<project root>\BEND_RULES.md`. A rule is a numbered line, such as `` 7. Never run `rm -rf` on anything outside `tmp/`. `` Headings, blank lines and other text are not rules. If a rule is written some other way (a bullet, a paragraph), bend-guard cannot see it. Tell the user which ones.

## 3. Sort every numbered line

There are three kinds:

- **hard**: the line names a path or a command and forbids it. bend-guard makes a rule, a law and a proof. Example: "Never delete or edit files in `specs/`."
- **ask**: the line says "ask first" or "run X before you finish". It becomes a question for the user or a reminder at the end of the turn. No proof. Example: "Don't install new npm packages without asking first."
- **judgment**: the line needs taste, so nothing can check it. It stays in CLAUDE.md. Example: "Match the existing code style."

Unsure? Pick the stricter kind: hard is stricter than ask, and ask is stricter than judgment. A line that names a path or command and says never or don't is hard or ask, not judgment. Judgment lines are not enforced at all.

A hard line gets one or more rule entries. These are the kinds:

| Kind | What it does | A line it fits | Entry |
| --- | --- | --- | --- |
| `NoChange` | nothing under `rel` may be written, edited, moved or deleted; reading is fine | "Never edit files in `specs/`" | `{"kind": "NoChange", "rel": "specs"}` |
| `NoReadOrChange` | nothing under `rel` may be read or changed | "Never edit `.env` or print it" | `{"kind": "NoReadOrChange", "rel": ".env"}` |
| `TreeDeleteOnlyUnder` | a recursive delete is allowed only under `rel` | "Never `rm -rf` outside `tmp/`" | `{"kind": "TreeDeleteOnlyUnder", "rel": "tmp"}` |
| `NoForcePush` | no forced git push | "Never run `git push --force`" | `{"kind": "NoForcePush"}` |
| `NoPushTo` | no push that names the branch | "Never push directly to `main`" | `{"kind": "NoPushTo", "branch": "main"}` |
| `TrustScript` | lets the package.json script `name` run without asking; forbids nothing; no law | "You may run `npm run lint` freely" | `{"kind": "TrustScript", "name": "lint"}` |

- Only one `TreeDeleteOnlyUnder` is allowed in a project, across all its lines. A line that names two folders ("never `rm -rf` outside `tmp/` or `build/`") stays `hard` with `"rules": []`, a `reason` that says bend-guard can allow recursive deletes under one folder only, and a `suggestion` to name one folder.

- One line can give several entries. "Never edit generated files in `build/` or `dist/`" gives two `NoChange` entries.
- bend-guard reads a rule more strictly than its words. "Never run `rm -rf` outside `tmp/`" blocks every recursive delete outside `tmp/` (`rm -r`, `Remove-Item -Recurse`, `git clean`), not just that spelling. Write the entry for the idea and say so in `reason`.
- Use `TrustScript` only when the line itself says a script may run freely. It is the one kind that loosens anything. Never add it to make a check pass. Do not add any rule the line does not ask for.
- `rel` is a plain path inside the project: lower case, `/` between parts, no leading or trailing `/`, no drive, no `.` or `..` parts, no wildcards, and only a-z, 0-9, `.`, `_` and `-` in a part. Windows ignores case, so `Docs/API/` becomes `docs/api`. `branch` and `name` hold only letters, digits and `. _ / -`.
- A hard line that fits none of the kinds (a wildcard such as `*.pem`, a folder name with a space, a rule about file contents): keep it `hard`, but give it `"rules": []`, a `reason` that starts `cannot express yet:`, and a `suggestion` that says in one sentence what kind of rule would fit. The user sees it flagged when they approve.

## 4. Write sort.json

```json
{
  "root": "c:/users/user/bend2_test",
  "lines": [
    {
      "line": 1,
      "text": "Never delete or edit files in `specs/`. They are signed off by the client; changes go through a pull request written by a person.",
      "kind": "hard",
      "reason": "Names a folder and forbids changing it: no write, edit or delete under specs.",
      "rules": [{ "kind": "NoChange", "rel": "specs" }]
    },
    {
      "line": 11,
      "text": "Match the existing code style; don't reformat files you aren't otherwise changing.",
      "kind": "judgment",
      "reason": "Needs taste; it stays in CLAUDE.md.",
      "rules": []
    }
  ]
}
```

- `root` is the normalised root. `lines` holds one entry per numbered line: none missing, none twice.
- `line` is the number printed in the file.
- `text` is the line without its `N. ` prefix, exactly as written, backticks included. The approve tool matches it against the file.
- `reason` is one plain sentence for the user, with no line break.
- `rules` is `[]` unless the line is hard. `suggestion` appears only on "cannot express yet" lines.
- It must be valid JSON: `\"` for a double quote and `\\` for a backslash inside a string.

The finished sample for the test project `bend2_test` is in `~\.claude\local-plugins\bend-guard\bend\fixtures\bend2_test\`: `rules.json` (its entries are the `lines`) and `ask.json`. Read it for the shape. Do not copy its content into another project.

## 5. Write ask.json

```json
{ "newTopLevelDir": true, "npmInstall": true, "testBeforeDone": "npm test", "lintBeforeDone": "npm run lint" }
```

All four keys are required.

- `newTopLevelDir`: true if a line says to ask before making a new top-level folder, else false.
- `npmInstall`: true if a line says to ask before installing packages, else false.
- `testBeforeDone`: the exact command a line says to run, and pass, before finishing (such as `"npm test"`), else `null`.
- `lintBeforeDone`: the same for the lint command (such as `"npm run lint"`), else `null`.

Only these four have a hook. For any other ask line, such as "Ask before deleting anything in `docs/`", keep the kind `ask`, say in `reason` that no ask hook exists for it yet, and put it in `claude-md.txt`.

## 6. Write claude-md.txt

Plain text for the user to paste into CLAUDE.md. Do not edit CLAUDE.md yourself. A heading line, then one bullet for each rule that bend-guard does not enforce: the judgment lines, the ask lines with no hook, and the "cannot express yet" lines (say so on those). Each bullet is the rule's own words and its line number:

```
## Project rules (from BEND_RULES.md; bend-guard does not enforce these)

- Match the existing code style; don't reformat files you aren't otherwise changing. (BEND_RULES.md line 11)
- Keep commit messages under 72 characters on the first line. (BEND_RULES.md line 13)
```

## 7. Run the draft check

Run exactly this in the Bash tool, with the `~` and the forward slashes as written, and nothing else on the line (no pipe, no redirect, no `cd`, no `&&`):

```
node ~/.claude/local-plugins/bend-guard/tools/draft-check.mjs <slug>
```

Why exactly this: bend-guard knows this one command and lets it run without asking the user, and this command's permission rule matches this spelling. Any other change makes it "not understood".

It takes about 5 minutes the first time, because the machine checks every proof. Later runs reuse the proofs whose Bend sources have not changed (a proof cache in WSL), so the time varies; a small edit to the rules is much quicker. Run it in the background and wait for the notice that it finished. Do not poll. (If you cannot run in the background, run it in the foreground with a 10-minute timeout.) The last line is `BEND-GUARD CHECK OK` or `BEND-GUARD CHECK FAILED`.

- **OK:** go to step 8.
- **FAILED:** read the lines above it.
  - A `gen:` or `draft:` line is about your files: a bad field, or a missing folder or wrong slug. A `gen:` line names the line and the field. Fix that and run again.
  - A `stage:`, `check:`, `compile:` or `probes:` line is rarely the data's fault. If it points at your data (a folder or branch name), fix that and run again. If not, stop and show the user the last lines of the output.
  - Fix data only. Never edit Bend files, templates or anything else in `~\.claude\local-plugins\bend-guard\`.
  - If the same failure comes back after two fixes, stop and show the user the output.

## 8. Tell the user

Keep it short and plain.

1. One line for each rule line, like `7: hard: recursive deletes only under tmp/ (TreeDeleteOnlyUnder)`.
2. Anything they should look at: "cannot express yet" lines, ask lines with no hook, rules that are not numbered lines, and any line where you were unsure and picked the stricter kind.
3. That `claude-md.txt` holds text for their CLAUDE.md, and where it is.
4. The next step. They type this themselves, in this session:

```
/bend-guard approve
```

It shows every line with its kind and law. When they have read it, they type `/bend-guard confirm`, and the proofs run again in the background (about 5 minutes; confirm never uses the proof cache). If the draft changes after they typed `approve` (for example you edit a file in it), `confirm` refuses and they must type `/bend-guard approve` again, so do not touch the draft files after step 7 unless you tell them to approve again. It is log-only by default: the project rules are written to the log but not enforced, while bend-guard's own protection always is. `/bend-guard confirm --enforce` enforces at once. (In their own PowerShell window, `node $env:USERPROFILE\.claude\local-plugins\bend-guard\tools\approve.mjs <project root>` does the same.)

Do not run `/bend-guard` or `approve.mjs` yourself. bend-guard denies it, and the command answers only the user's own typing.
