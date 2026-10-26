# bend-guard

bend-guard checks every tool call Claude Code makes in a project that has an approved `BEND_RULES.md`. It turns the hard rules of that file into a checker written in Bend 2. The checker comes with laws, and the machine checks a proof of each law. Clef, a small hosted model on OpenRouter, gives a second opinion that can only make an answer stricter.

**New here?** Start with [GUIDE.md](GUIDE.md): a short guide to installing, approving rules and day-to-day use. This README is the full reference.

**Download:** `git clone https://github.com/DanielDNewton/bend-guard "$env:USERPROFILE\.claude\local-plugins\bend-guard"`. It must be that exact folder; the rest of the install is in [Setup](#setup).

**Status (2026-10-26):** every law is proven by Bend's checker and again by the Lean kernel (for the sample rules the build says `11 project laws, BEND-GUARD CHECK OK`). Tests: 4,350 policy cases, 257 hook tests, and 233 tool, replay and Clef-benchmark tests pass, and headless scenarios against the real Claude Code engine pass in every permission mode (see Testing). It has not yet been used in daily work by a person, and Clef's thresholds are untuned, because no OpenRouter key has been used yet. That is why the first approval is log-only (see Setup): the log shows what would be blocked before anything is.

**What to expect.** It asks on about a third of calls (44.9% in main sessions in the replay) and sends about 28% to Clef, which gives no answers until you add a key, so those just ask. That is the cost of never allowing what it cannot read (see Noise).

**To turn it off:** `/bend-guard log-only` (rules only, so not "off"), `/plugin` and disable `bend-guard` (the whole plugin; your approvals stay), or edit one project out of `approved.json`. Details: "Turning it off" under Setup.

Paths below start at your home folder, `%USERPROFILE%` (in PowerShell `$env:USERPROFILE`), also written `~`.

## What it does

**Scope.** bend-guard acts only when the session folder is an approved project or inside one. Example: with `%USERPROFILE%\myproject` approved, a session started in `%USERPROFILE%\myproject\src` is checked. A session started in `%USERPROFILE%\Documents` is not: bend-guard does nothing there. The same goes for a session started above the project, in `%USERPROFILE%`, even though it can reach the project's files. Inside an approved project every tool call is checked: built-in tools, MCP tools, subagents and workflow agents.

**Three verdicts.** When several things apply to one call, the strictest verdict wins: Deny beats Ask, and Ask beats Allow.

| Verdict | What happens | Example |
| --- | --- | --- |
| Allow | the call runs | `cat README.md` |
| Ask | the user gets Claude Code's permission prompt, with bend-guard's reason | `npm install left-pad` |
| Deny | the call is refused and Claude is told why | `rm -rf specs` |

Two more facts:

- **Anything bend-guard does not understand is never allowed on its own.** Example: `python -c "import shutil; shutil.rmtree('specs')"` is not a command it knows, so the user is asked.
- **Where nobody can be asked, an Ask becomes a Deny.** A subagent that runs `jq . package.json` is refused with "Ask the user in the main session".

**Who can be asked.** The glue decides this and passes it to the policy as a fact. A person counts as present when the session started interactive, or when Claude Code itself reports `approver = person` on a main-session call (its dialog reaches the user). The host's own dialog (`approver = host`, the IDE extensions) counts only when the surface is known. A headless run (`claude -p`, the SDK) has no approver, so nobody is asked and every Ask there is a Deny. Agents are never asked. Because the glue decides this, it is listed under "Trusted, not proven" below.

**What happens to a call.** Claude asks to use a tool. Claude Code fires `tool.call` first, and then, inside it, `tool.check` (after the PreToolUse hooks). `tool.call` carries no approver, so bend-guard judges the call there, once, both for when someone can answer an ask and for when nobody can, and keeps both verdicts for that `tool_use_id`. The *translator* (Bend) reads the command into actions, for example "delete the folder `specs`". The *policy* (Bend) judges those actions: self-protection first, then the project rules, then the built-in asks. Sometimes Clef gets a say. Out come Allow, Ask or Deny. A Deny is refused at once, in `tool.call`. Otherwise `tool.check` picks the verdict for whoever can answer: an Ask reaches the user's permission prompt with bend-guard's reason, and where nobody can answer (a headless run, an agent) it is refused. If a hook beneath bend-guard changed the input on the way, `tool.check` judges the changed input again.

**The sample rules.** The examples in this file use a sample `BEND_RULES.md` with these numbered lines (rules 11 to 15 are judgment rules such as "Match the existing code style"):

```
1. Never delete or edit files in `specs/`.
2. Never edit `.env` or anything in `secrets/`, and never print their contents.
3. Never edit generated files in `build/` or `dist/`; change the source and rebuild.
4. Don't create new top-level folders without asking first.
5. Never run `git push --force` or `git push -f`.
6. Never push directly to `main`; work on a branch.
7. Never run `rm -rf` on anything outside `tmp/`.
8. Don't install new npm packages without asking first.
9. Run `npm test` before saying a task is done, and show that it passed.
10. Run `npm run lint` and fix any errors before finishing.
```

The drafts made from it are in `bend\fixtures\bend2_test`.

**Examples**, for a project with the sample rules (rules 1, 2 and 6, and bend-guard's own protection):

| Tool call | Enforce mode | Log-only mode |
| --- | --- | --- |
| `cat README.md` | Allow | Allow |
| `cat specs/a.md` | Allow, after a Clef check (Ask if Clef is unsure or silent) | Allow |
| `rm -rf ./SPECS/../specs` | Deny (rule 1: it sees through case and `..`) | Allow, logged as would-deny |
| `Edit` of `specs\a.md` | Deny (rule 1) | Allow, logged as would-deny |
| `git push origin HEAD:main` | Deny (rule 6) | Allow, logged as would-deny |
| `git push` with no branch | Ask (the branch is not visible in the command) | Allow, logged as would-ask |
| `npm install left-pad` | Ask (it runs install scripts) | Allow, logged as would-ask |
| `python -c "..."`, if Clef says risky | Deny | Deny |
| `jq . package.json`, even if Clef says safe | Ask (Clef cannot loosen) | Ask |
| the same `jq` in a subagent | Deny: "Ask the user in the main session" | Deny |
| `Edit` of `%USERPROFILE%\.claude\settings.json` | Deny (self-protection) | Deny |
| `cat ~/.claude/bend-guard/openrouter.key` | Deny (self-protection) | Deny |
| `rm ~/.claude/settings.jso?` | Deny (not understood, and the wildcard can match a protected file) | Deny |
| `python -c "open('C:/Users/user/.claude/settings.json','w')"` | Deny (not understood, and it names a protected file) | Deny |
| `python -c "print(open('.env').read())"` | Deny (rule 2: not understood, and it names `.env`) | Deny |

(In examples, `C:\Users\user` stands for your own home folder.)

**Log-only and enforce.** In log-only mode, everything bend-guard understands is let through, and the log records the verdict that enforce mode would have given. Self-protection is still enforced, and anything bend-guard does not understand still asks. Enforce mode applies everything. Nothing is shown in the chat for a would-be refusal; the log's verdict and reason columns name the rule line. Switch over once the log looks right.

**Self-protection.** Always on, in both modes, and even if the user says yes to an ask. bend-guard refuses any change to:

- every approved project's `BEND_RULES.md`;
- Claude Code's settings: `~\.claude\settings.json`, `settings.local.json`, `~\.claude.json`, every approved project's `.claude\settings.json`, `settings.local.json` and `.mcp.json`, and those three files by name in any folder (a session started there loads them);
- the whole `~\.claude\local-plugins` folder (bend-guard, any other local plugins, the marketplace file) and `~\.claude\plugins`;
- bend-guard's state folder, `~\.claude\bend-guard`;
- shell profiles (Bash and PowerShell) and `C:\ProgramData\ClaudeCode`;
- `.git\hooks`, `.git\config` (also of submodules, worktrees and bare repositories), `~\.gitconfig`, `~\.config\git` and the system git config, because they decide what code runs later. These are refused in both modes, log-only included. A `git config` command that changes a setting (`git config core.hooksPath x`, `git config --global alias.x ...`, `--unset`, `--edit` and the like) is refused the same way; reading settings (`git config --get`, `--list`, `git config user.name`) is allowed.
- Claude Code's `shell-snapshots`, `session-env`, `hooks` and `dev-mods` folders under `~\.claude`, the Windows Startup folder, `~\.ssh\config`, `~\.npmrc`, `~\.curlrc`, `~\.wgetrc` and `~\.config\gh`. Because bend-guard understands some `curl`, `gh` and `pip` commands, also the other places they read settings from: `~\_curlrc`, `~\AppData\Roaming\.curlrc` and `_curlrc`, `~\AppData\Roaming\GitHub CLI`, `~\AppData\Roaming\pip` and `~\pip`.
- **Environment and config files** that change what a command does while bend-guard thinks it understands the command: the home-owned folders on PATH (`~\bin`, `~\.local\bin`, `~\.cargo\bin`, npm's global folder, `WindowsApps`, `WinGet\Links`), any folder's `.npmrc`, git's `commondir`/`gitdir`/`HEAD` tricks, Python's user-site folders (where a `.pth` file runs at every Python start), and changes to the user environment (`setx`, `reg add`, `reg delete` and the like, `SetEnvironmentVariable`). Also, `OPENSSL_*`, `SSL*` and `REQUESTS_*` variables cannot be set in front of an allowed command. Reading `HKCU:\Environment` and setting a variable for one process are refused too (stricter than needed); `reg query` still only asks.

A write to `.gitattributes` or `.git\info\attributes` asks. Reading the OpenRouter key file is refused too.

**Calls bend-guard does not understand but that can reach a protected file** are refused, not asked. This covers a wildcard in any command bend-guard does not understand that can match a protected name (`rm ~/.claude/settings.jso?`, `rm -rf .git/hook*`, `python x.py ~/.claude/*`, or `rm *.md` and `python x.py *.md` in the project folder, which can match `BEND_RULES.md`), a wildcard in a protected `.claude`, `.git` or `Documents` path, also before its last part (`node x.js ~/.cla*/settings.json`), more than 64 wildcard words in one such command, and a command part, MCP tool or `SendMessage` whose text names a protected path (`python -c "open('C:/Users/user/.claude/settings.json','w')"`) or uses a short name like `C:\Users\user\.claude\LOCAL-~1`. A command that only reads such a file but is not understood is refused too, for example `for f in ~/.claude/hooks/*; do cat "$f"; done`. To read a protected file, use the Read tool.

**Shell commands bend-guard does not understand that name a no-read folder** are refused, not asked. Example: with rule 2 keeping `.env` and `secrets\` unreadable, `python -c "print(open('.env').read())"` and `python x.py ../secrets/k.txt` (from `src`) are refused in both modes, whatever Clef says and even if the user would say yes. Spellings that only look alike, such as `.env.example`, `dotenv` or `my-secrets.txt`, do not count. A command run from inside such a folder that does not name it still asks. For a folder that may be read but not changed (rule 1, `specs\`), the dialog adds a line such as `It mentions specs\ (rule 1).`, so the user sees it before they answer. In the real-call replay this refused 9 calls that used to ask.

**The second opinion (Clef).** Clef is asked in two cases, only for Bash, PowerShell and Monitor commands in the main session:

- **Triage.** A command bend-guard does not understand. If Clef is at least 80% sure it is dangerous, it is refused. Example: `python -c "import shutil; shutil.rmtree('specs')"` comes back risky and is denied. Otherwise the user is asked as usual.
- **Veto.** A shell command that reads inside a protected folder, such as `cat specs/a.md`. If Clef is at least 50% sure it is risky, or at least 30% unsure what it does, the user is asked. The `Read` tool is not sent to Clef. Agents are never sent to Clef either: the rules already allow such a read, and Clef could only tighten it.

If Clef does not answer (no key, a timeout, an error, credit used up), the answer is "no answer", and that means Ask (Deny in agents). It never means Allow. The 80/50/30 limits are starting values, not tuned. A benchmark to tune them is ready but has not run (see "The Clef benchmark").

**The "ask first" and "before finishing" rules** (4, 8, 9 and 10 in the sample file). These are plain TypeScript, not proven. They can only add an ask or a reminder, and a Deny from the policy always wins:

- Rule 4: a new top-level folder asks. Example: `Write` of `tools\x.ts` when `tools\` does not exist yet.
- Rule 8: the policy already asks about every `npm install`, because install scripts run. The hook adds the package names to the reason.
- Rules 9 and 10: if files changed in a turn and `npm test` and `npm run lint` have not passed since, a reminder line is added to the end of Claude's answer. It is a reminder, not a block (see Known gaps).

## What is proven

Each law is a statement about the checker for every possible input, not for a list of test cases. Bend checks each proof by machine, twice: with its own checker, and again with `--verdict`, which uses a small kernel that is itself proven in Lean. If a proof fails, the approve tool refuses the policy, so it is never installed.

The laws hold whatever the translator says a command does, whatever Clef answers, and whatever the call's facts are.

**Verdicts** (`bend\laws\verdict\LAWS.bend`)

| Law | In plain English |
| --- | --- |
| `max_ge_left`, `max_ge_right` | The stricter of two verdicts is never looser than either one. |
| `deny_is_top` | A Deny always survives. |

**Paths** (`bend\laws\path\LAWS.bend`)

| Law | In plain English |
| --- | --- |
| `under_refl` | Every path is under itself. |
| `under_child` | A rule's folder, such as `specs`, is under the project folder. |
| `under_trans` | Under a path that is under C means under C. |
| `overlaps_sym` | Overlap works the same both ways round. |
| `under_overlaps` | A path under B overlaps B. |
| `eq_under` | Equal paths are under each other. |
| `ancestors_comparable` | Two folders that both contain the same path are nested, one inside the other. |
| `norm_clean` | A normalised path never has an empty, `.` or `..` part. |

**The generic policy** (`bend\laws\guard\LAWS.bend`, and `run_is_translator_then_policy` in `bend\base\Policy.bend`)

| Law | In plain English |
| --- | --- |
| `unknown_never_allowed` | A command bend-guard does not understand is never allowed, unless the user said yes to that exact call. This holds in log-only mode too. |
| `no_ask_without_person` | Where no person can answer (a subagent, or nobody to ask), bend-guard never asks. It allows or refuses. Whether anyone can be asked is a fact the glue passes in (see "Who can be asked"); the law holds for whatever it says. |
| `combine_monotone` | Clef's answer can only make a verdict stricter, never looser. |
| `finish_monotone` | Settling an ask (asking the user, or refusing when nobody can be asked) keeps a stricter verdict at least as strict. |
| `clef_cannot_loosen` | Whatever Clef answers, or if it does not answer, the final verdict is at least as strict as without Clef. |
| `named_noread_unknown_denied` | A shell command bend-guard does not understand that names a path a no-read rule protects (such as `.env` or `secrets`) is refused, whatever Clef says, in log-only mode too. |
| `run_is_translator_then_policy` | The function the glue calls is the translator followed by the proven policy. So the laws cover every real call. |

**Self-protection** (`bend\laws\self\LAWS.bend`)

| Law | In plain English |
| --- | --- |
| `self_protection` | Any call that changes bend-guard's own rules, code, key or state, or Claude Code's settings, is denied. This holds in log-only mode and even if the user said yes. |
| `key_unreadable` | Any call that reads the OpenRouter key file is denied, the same way. |
| `changes_hits`, `key_hits` | The two steps behind those: such a change, or such a read, always counts as a self-protection hit. |

**Project rules** (`bend\laws\rules\LAWS.bend`, proven once for every rule table). Outside log-only mode:

| Rule kind | Law | In plain English |
| --- | --- | --- |
| `NoChange` | `rule_nochange_denies` | A call that changes anything under the folder is denied. |
| `NoReadOrChange` | `rule_noread_change_denies` | A call that changes anything under the folder is denied (the same as `NoChange`). |
| `NoReadOrChange` | `rule_noread_read_denies` | A call that reads a file under the folder is denied. |
| `TreeDeleteOnlyUnder` | `rule_tree_delete_denies` | A recursive delete of a folder in the project (or containing it) that is not under the allowed folder is denied. |
| `NoForcePush` | `rule_force_push_denies` | A forced push run inside the project is denied. |
| `NoPushTo` | `rule_push_to_denies` | A push that names the branch, run inside the project, is denied. |
| (every table) | `read_allowed` | A plain read of a file that no rule names, that is not the key file, not behind a link and in no double-check zone, is allowed whatever Clef says. This stops the policy from being "safe" by refusing everything. |

**Per project.** When you approve a project, the generator makes one instance of these for each of its rules. For the sample file: `specs_protected`, `env_protected`, `env_unreadable`, `secrets_protected`, `secrets_unreadable`, `build_protected`, `dist_protected`, `force_push_denied`, `push_main_denied`, `tree_delete_only_tmp` and `reads_allowed`. Each one is shown to you in plain English before you approve it. After the proofs, fixed probe calls are put through the compiled checker. Example: for `NoChange specs`, an `Edit` of `specs\__probe__` must be denied. A proven law that does not protect in practice fails there.

## What is not proven

**Limits of the idea**

- **What a program does after it starts.** If you approve `npm test`, the test code runs with Claude's full rights. A test that deletes `specs\` would succeed. That is why every `npm test`, `npm run <script>` and `npm install` asks. The proofs cover what the command line says, not what the started program does.
- **The English rule and the law can differ.** No proof can check that a law says what the sentence meant. Example: if a draft said `spec` instead of `specs`, the law for `spec` would be proven perfectly and would protect the wrong folder. That is why you read every line of BEND_RULES.md beside its kind and its law when you approve. The probe calls catch a policy that fails to protect what its own table says. They cannot catch a typo in the table itself.
- **Bend's model of a command can be wrong.** If the checker believes `cp a b` only writes `b`, and a flag makes it write somewhere else, no proof notices. This is limited by knowing only a small, fixed set of commands, flags and tool argument names. Anything else is "not understood".
- **Judgment rules are not enforced.** "Match the existing code style" stays in CLAUDE.md.
- **The user's own actions are not limited.**

**Trusted, not proven**

- **Bend itself.** Its parser, its translation into the Lean kernel, and above all its JavaScript output are not proven. The Bend version is pinned and its hash is checked.
- **The glue.** The TypeScript that passes facts to the checker, compares fingerprints, calls Clef and enforces the time limit. It also decides whether anyone can be asked (a person is present, or not), and the proofs take that as given. It is type-checked and tested against the real engine in headless runs, in every permission mode, but never yet with a person answering the dialog.
- **The proof cache.** `tools\prove.sh` keeps a list of proofs it has already checked in WSL (`/root/.bend-guard-proofs`). Draft checks trust it; approving never does (it proves everything again).
- **Claude Code itself.** That it runs the hook before every call, in every mode and every agent, and honours the answer. The order of its two events was checked live (see Testing), and so was every permission mode, headless: with nobody to answer, a command bend-guard does not understand was refused in default, acceptEdits, bypassPermissions, dontAsk and plan modes, and bend-guard's check also ran for an MCP tool, a subagent and a skill that runs as its own agent. What a person sees in the dialog is checked by hand (see "Try it by hand").
- **Clef.** Not trusted for safety at all. It can only tighten, which is proven.

## Known gaps and limits

These are the ways bend-guard can let something through, and what it costs. Know them before you rely on it.

- **Links are not checked.** Symlinks, junctions and hard links are not looked at (the checker always gets an empty list of links). Windows' built-in compatibility junctions (`C:\Documents and Settings` and the like) are refused by name. Example: if `docs\latest` is a symlink to `specs\`, an edit of `docs\latest\a.md` is not seen as an edit of `specs\`.
- **`mv` and `cp` into a folder that does not exist yet.** bend-guard sees the new folder's own name, not what lands inside it. Example: the rules protect `docs\signed\`, and `mv drafts docs` is run when `docs\` does not exist. The renamed folder could bring a `signed\` folder with it.
- **CDPATH and shell aliases.** bend-guard reads the words as typed. If the shell has an alias or function (say `alias rm=...`), or CDPATH is set, a command can do something other than it says. Example: with CDPATH set, `cd specs` may land in another `specs` folder.
- **`git push` to a plain name that is really a folder.** bend-guard treats a plain name as a configured remote. Git treats a name that is not a remote as a local path. Example: `git push backup feature`, where `backup` is a folder with a repository in it, writes into that folder, and bend-guard does not see it.
- **Rules 9 and 10 are reminders, not blocks.** The end-of-turn event cannot stop a turn from ending. Claude can still finish without running `npm test`, but the reminder line is added to its answer.
- **Branch names are compared exactly.** On a remote that ignores case, a push to `Main` could reach `main` without matching the rule for `main`.
- **Cost.** In an approved project every checked call starts one node process: about 100 to 200 ms. A call that reaches Clef adds up to 3 seconds. The check has a 4-second limit, and a call that goes over is refused.
- **Outside approved projects bend-guard does nothing.** An agent working in another folder can edit bend-guard's own files, because self-protection only runs inside approved projects. The fingerprint catches a changed `policy.mjs` (see below), but not a changed `hooks\` file, and not an `approved.json` edited to match. Keep other Claude sessions away from `%USERPROFILE%\.claude`.
- **Noise.** It still asks about a third of all calls (see Noise below). Most of that is commands that run other code (`python`, `node`, `ssh`, `fly`, loops around them), which bend-guard can never read soundly. It also asks in a few places where it could be smarter: a search of the whole project covers `.env` and `secrets\`, so it asks; a `grep` pattern with a wildcard reads the folder as a tree; every MCP tool is "not understood" and asks, by design; a command with `$( )` or a variable around it is not read. The `suggest.mjs` tool shows which commands to teach Bend first.
- **Settings files bend-guard does not protect.** A project's own `.npmrc` (Claude may write it) can move where npm writes its log and cache, also for the npm commands bend-guard allows (`npm ls`, `npm view`, `npm outdated`). The write lands in npm's own folders, not a protected one, unless the setting points there.
- **Environment and config, what is still not seen.** The protected PATH folders are a fixed list of the usual home-owned ones; a PATH folder elsewhere is not seen, because the session's real PATH is not passed in. Python's user-site folders are protected in their usual places only (a `.pth` file in a system site folder Claude can write is not seen). A `NAME=x cmd` prefix such as `GH_CONFIG_DIR=x gh pr list` asks instead of being refused. A whole folder that already holds `HEAD`, `objects` and `refs`, copied in with `cp -r`, can become a bare git repository bend-guard cannot see. A Windows Documents folder moved away from `Documents` or `OneDrive\Documents` is not seen, so a PowerShell profile there is not protected.
- **Not yet tried by a person.** The permission dialog, the IDE extensions and long daily use are untested. The first approval is log-only for that reason.
- **Smaller ones.** `Remove-Item` without `-Recurse` on a folder that has files in it is read as a single delete. `echo` and `pwd` under PowerShell are not understood, and an unknown PowerShell command makes later relative paths unknown. PowerShell turns number-like words into numbers (`Remove-Item 1kb` deletes a file named `1024`), and bend-guard reads the word as written; no protected name looks like a number. A `NAME=x cmd` prefix is not read, so it asks. One word of about 40,000 characters makes the checker fail, and a failed check refuses the call. If BEND_RULES.md starts with a byte-order mark, the "changed since approval" notice may show every session.

## Setup

**What you need:**

- Windows, with your home folder on drive `C:`;
- Node 22 or newer at `C:\Program Files\nodejs\node.exe` (the checker starts it by that full path);
- Git, to download bend-guard;
- Claude Code 2.1.310 (the version the hook API was checked against);
- WSL with the `Ubuntu-24.04` distro, Bend 2.0.39 and Lean 4.34.0 (step 1; the `bend` binary must have the pinned hash), and about 12 GB of memory for WSL (RAM plus swap; see "The WSL toolchain");
- optional but recommended, an OpenRouter key (step 3).

### 1. Set up WSL (once)

1. In an administrator PowerShell: `wsl --install -d Ubuntu-24.04`. Restart if asked, and finish the distro's first start. bend-guard's scripts run in it as root.
2. Give WSL enough memory. Create `%USERPROFILE%\.wslconfig`, then run `wsl --shutdown`. One compile peaks near 7.7 GiB and a proof run near 10 GB, so use at least 12 GB of memory plus swap; more is safer. A file that works:

   ```
   [wsl2]
   memory=22GB
   swap=16GB
   ```
3. In the distro, as root, download the Bend 2.0.39 Linux x64 tarball. Its address, its SHA-256 and the source commit are in `BEND_VERSION`. Check the hash before you unpack it:

   ```
   sha256sum <the tarball>          # must equal the tarball hash in BEND_VERSION
   mkdir -p /opt/bend-2.0.39 && tar -xzf <the tarball> -C /opt/bend-2.0.39   # so that /opt/bend-2.0.39/bin/bend exists
   sha256sum /opt/bend-2.0.39/bin/bend    # must be 2ec160fa4486d33aff51e9eedcc294d6b531dc10c279c00b0c00685dae2045cd
   ```
4. Install Lean 4.34.0 with elan, as root: `curl https://elan.lean-lang.org/elan-init.sh -sSf | sh -s -- -y --default-toolchain leanprover/lean4:v4.34.0` (it goes to `/root/.elan`).
5. Write `/etc/profile.d/bend.sh`:

   ```
   export PATH=/opt/bend-2.0.39/bin:/root/.elan/bin:$PATH
   export BEND_NO_TELEMETRY=1
   ```
6. Check: `wsl -d Ubuntu-24.04 -u root -- bash -lc 'bend --version && lean --version'`. After step 2, `node tools\doctor.mjs` must also say `ok` on its WSL lines. Never run `bend update`.

### 2. Download and install

bend-guard must live at exactly `%USERPROFILE%\.claude\local-plugins\bend-guard` (see "Where bend-guard must live" below). So a plain `claude plugin marketplace add` of the GitHub repository does **not** work: Claude Code would put it somewhere else, and bend-guard would refuse to run. Instead, clone it into that folder and install it from a local marketplace.

1. Clone it, in your own PowerShell:

   ```
   git clone https://github.com/DanielDNewton/bend-guard "$env:USERPROFILE\.claude\local-plugins\bend-guard"
   ```

2. Make the local marketplace file, `%USERPROFILE%\.claude\local-plugins\.claude-plugin\marketplace.json`:

   ```
   New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude\local-plugins\.claude-plugin" | Out-Null
   notepad "$env:USERPROFILE\.claude\local-plugins\.claude-plugin\marketplace.json"
   ```

   If you have none yet, this complete file works (put your own name or handle in `owner`):

   ```json
   {
     "name": "local-mods",
     "owner": { "name": "your-name" },
     "plugins": [
       { "name": "bend-guard", "source": "./bend-guard" }
     ]
   }
   ```

   If the file already exists, add `{ "name": "bend-guard", "source": "./bend-guard" }` to its `"plugins"` list and keep its own `"name"`.

3. Register the marketplace once (skip this if it is already registered), install and enable the plugin, then restart Claude Code:

   ```
   claude plugin marketplace add "$env:USERPROFILE\.claude\local-plugins"
   claude plugin install bend-guard@local-mods
   claude plugin enable bend-guard@local-mods
   ```

   (If the plugin is already enabled after the install, the enable line just says so.)

**The marketplace name.** Any marketplace name works. bend-guard accepts being loaded from its folder or from Claude Code's install copy at `%USERPROFILE%\.claude\plugins\cache\<marketplace>\bend-guard\<version>`, whatever `<marketplace>` is, and the doctor finds any `bend-guard@<marketplace>` install. The plugin's own name must stay `bend-guard`. This file uses `local-mods`; if your marketplace has another name, use `bend-guard@<that name>` wherever this file says `bend-guard@local-mods`.

**The `claude` command.** Every `claude plugin ...` command in this file needs the Claude Code command line. If `claude` is not on your PATH (for example, when the only copy is the one inside the VS Code extension), run it by its full path in PowerShell:

```
$claude = "$env:USERPROFILE\.vscode\extensions\anthropic.claude-code-2.1.310-win32-x64\resources\native-binary\claude.exe"
& $claude plugin install bend-guard@local-mods
```

Inside Claude Code, `/plugin` does the same install, enable and disable. Wherever this file says `claude plugin ...`, that is what it means.

Edit the marketplace file yourself, or before bend-guard is on. Once it is on, it refuses any Claude change in the `local-plugins` folder. bend-guard does nothing until you approve a project.

`claude plugin install` copies the plugin to `%USERPROFILE%\.claude\plugins\cache\local-mods\bend-guard\<version>`, and Claude Code runs the hooks from that copy. A later change to the plugin folder does not reach the copy while the version number stays the same. So after any change to bend-guard, refresh the copy (see "Updating" below and "Changing bend-guard itself"). `node tools\doctor.mjs` says whether the copy matches, or that Claude Code runs bend-guard straight from its folder.

Then check the install in your own terminal (it reads only, and makes no network call):

```
node "$env:USERPROFILE\.claude\local-plugins\bend-guard\tools\doctor.mjs"
```

It prints one line per check (`ok`, `PROBLEM` with the fix, `note` for something optional that is missing, such as the key, or `skipped`): node, the plugin's place, the installed copy, the WSL distro, the pinned `bend`, `approved.json`, the policy fingerprint, each approved BEND_RULES.md, and whether the key file exists (never its contents). Fix each `PROBLEM` line. Before the first approval it reports that `approved.json` does not exist; that is expected. `--skip-wsl` leaves out the two WSL checks. `--clef` also makes one paid Clef call to check the key. `/bend-guard doctor` in Claude Code shows the same lines (without `--clef`).

**Where bend-guard must live.** Every place comes from your own home folder (`%USERPROFILE%`); no code names a user, and a test fails if any does. The supported layout:

- Windows, with the home folder on drive `C:`;
- the plugin at `%USERPROFILE%\.claude\local-plugins\bend-guard`;
- state in `%USERPROFILE%\.claude\bend-guard`, drafts in `%USERPROFILE%\.claude\bend-guard-drafts`.

If the home folder is not on `C:`, or Claude Code loads the hooks from anywhere other than that plugin folder or its own install copy under `%USERPROFILE%\.claude\plugins\cache`, bend-guard refuses every call where it is meant to guard (a folder with a BEND_RULES.md, or an approved project), with a message naming the folder it expects. Elsewhere it stays silent. The `/bend-guard` commands that approve or switch modes refuse too.

**Updating.** In your own terminal (bend-guard only checks Claude's tool calls, not yours):

1. Disable bend-guard (`/plugin`, or `claude plugin disable bend-guard@local-mods`) and restart Claude Code.
2. Pull the new version, and see whether the policy sources changed:

   ```
   git -C "$env:USERPROFILE\.claude\local-plugins\bend-guard" pull
   git -C "$env:USERPROFILE\.claude\local-plugins\bend-guard" diff --stat ORIG_HEAD HEAD -- bend tools/gen.mjs tools/probes.mjs
   ```

3. Refresh the installed copy, enable it, check it and restart (the same commands as step 3 of "Changing bend-guard itself"):

   ```
   claude plugin uninstall bend-guard@local-mods
   Remove-Item -Recurse -Force "$env:USERPROFILE\.claude\plugins\cache\local-mods\bend-guard"   # only if it is still there
   claude plugin install bend-guard@local-mods
   claude plugin enable bend-guard@local-mods
   node "$env:USERPROFILE\.claude\local-plugins\bend-guard\tools\doctor.mjs" --skip-wsl
   ```

   The doctor's `installed copy` line should say `ok`.
4. If the `diff` in step 2 listed any file (anything under `bend\`, or `tools\gen.mjs` or `tools\probes.mjs`), approve every project again: `/bend-guard:compile`, then `/bend-guard approve` and `/bend-guard confirm` (steps 4 and 5). Until you do, the policy you approved earlier keeps running, without what the update changed in it. If nothing was listed, the restart is enough.

**Turning it off.** Three levels:

- *The whole plugin:* `/plugin` in Claude Code, or `claude plugin disable bend-guard@local-mods` (see "The `claude` command" above), then restart Claude Code. Your approvals stay; enabling it again picks them up.
- *Temporarily, rules only:* `/bend-guard log-only`. Project rules are then only logged. Self-protection and asking about commands bend-guard does not understand stay on, so this is not "off".
- *One project:* there is no command for this (no `approve.mjs --remove`). To stop guarding one project, edit `%USERPROFILE%\.claude\bend-guard\approved.json` yourself in your own editor (Claude cannot) and delete that project's entry under `"projects"` (the key looks like `"c:/users/user/myproject"`), then restart Claude Code. Keep the file valid JSON; if you break it, bend-guard refuses every call in approved projects until you fix it (see "Fingerprint mismatch"). The project's rules stay inside the compiled `policy.mjs` but are no longer tied to any folder. Approving that project again brings it back.

### 3. Add the OpenRouter key (optional, recommended)

See "The OpenRouter key, and what is sent" below. Without it, Clef never answers. Until it exists the doctor shows a `note` line for it, which is not a problem. Once it does, run the doctor with `--clef` once to check it (one paid call, a fraction of a cent).

### 4. Draft the rules

Write the project's `BEND_RULES.md` (numbered lines; see "The sample rules"). In a Claude Code session in the project, run:

```
/bend-guard:compile
```

Claude sorts each numbered line of BEND_RULES.md as hard, ask or judgment, writes the result as data in `%USERPROFILE%\.claude\bend-guard-drafts\<slug>\`, and runs the draft check. The slug is the project folder with `:`, `/`, `.` and spaces turned into `-`, for example `c--users-user-myproject` for `C:\Users\user\myproject`. Two folders with the same slug (such as `a-b` and `a/b`) cannot both be approved; the draft check says so. The draft check builds the Bend rules and laws and has the machine check every proof. The first run takes about 5 minutes, because the machine checks every proof. Later runs reuse the proofs whose sources have not changed (the cache `/root/.bend-guard-proofs` in WSL, keyed on the Bend binary and the `.bend` sources), so a run after a small rules edit is much shorter. Any changed `.bend` source is proven again. Delete that file to force a full re-proof. It ends with `BEND-GUARD CHECK OK`. Claude also writes `claude-md.txt`: the judgment rules for you to paste into CLAUDE.md.

### 5. Approve it

In the Claude Code session in the project, type:

```
/bend-guard approve
```

It shows every numbered line with its kind and its law (or why no law was made), flags lines that look hard but were sorted as ask or judgment (`CHECK THIS`), and shows the asks. The first time, it also shows the core laws, one plain line each. Read it all, then type:

```
/bend-guard confirm
```

This re-proves everything in the background (about 5 minutes; it never uses the proof cache, so the time does not depend on earlier runs), checks Bend's hash, compiles `policy.mjs`, runs the probe calls, and records the fingerprints. Keep working: the status line under the prompt shows its progress, and a notice says when the rules are live. Keep the session open until then (closing it, or `/reload-plugins`, stops the approval). The first approval is log-only. `/bend-guard confirm --enforce` enforces at once; `--log-only` is accepted too and is the default.

`confirm` approves exactly what `approve` showed. Type it in the same session, within 30 minutes. It refuses, and you type `/bend-guard approve` again, when:

- BEND_RULES.md, the draft (even if Claude or you edited it after you typed approve) or the approvals changed in between;
- more than 30 minutes have passed;
- the session has moved to another project;
- another approval or a mode switch is already running;
- there is nothing to confirm yet.

What `approve` showed is forgotten when a new session starts, so confirm in the same session.

**Only you can run these.** bend-guard's default rule denies any Claude tool call that runs `approve.mjs` or invokes `/bend-guard`. The command also answers only your own typing, not another plugin, a scheduled task or a message from another session. After installing or updating bend-guard, run `/reload-plugins` once (or start a new session) so that `/bend-guard` appears.

**Or in a terminal.** The same approval runs in your own PowerShell window. In Git Bash's own window, put `winpty` in front. It shows the same lines and asks you to type `approve`:

```
node "$env:USERPROFILE\.claude\local-plugins\bend-guard\tools\approve.mjs" <project folder>
```

### 6. Log-only for a few days

Project rules are logged, not enforced. Self-protection is enforced from the start. Look at the log (see Logs below), and run `suggest.mjs` to see what was not understood. Work through "Try it by hand" before you switch to enforce.

### 7. Switch to enforce

When the log looks right, type:

```
/bend-guard enforce
```

It changes only the mode, for every approved project at once. It does not redo the proofs. `/bend-guard log-only` switches back. Approving a project again without `--enforce` also puts every project back in log-only mode. In a terminal, the same is `approve.mjs --enforce --mode-only` (or `--log-only --mode-only`).

### 8. Look at the state

Any time: type `/bend-guard status`, or run `approve.mjs --status` in a terminal.

### 9. Ask why

In log-only mode nothing is shown in the chat for a call enforce mode would refuse. Two commands show it without opening the log. Both only read: they write no log line and change nothing.

- `/bend-guard why [n]` lists the last n calls bend-guard checked in this session (default 5, at most 20): the tool, the command (secrets masked, one line, at most 120 characters), the verdict, the enforce-mode verdict when it differs, and the reason with its BEND_RULES.md line. Example line: `2. Bash: rm -rf specs -> allow (enforce mode: deny). bend-guard rule (BEND_RULES.md): ... (BEND_RULES.md line 1: "Never delete or edit files in `specs/`. ...")`.
- `/bend-guard test [Bash|PowerShell] <command>` judges a command as if Claude ran it now in this session's folder, with you there to answer, and shows the verdict in enforce mode and in log-only mode, the current mode, and what bend-guard read. Nothing runs. It never calls Clef; for a command bend-guard does not understand it says Clef would be asked. Example: `/bend-guard test rm -rf specs` gives `enforce mode: deny` and `log-only mode: allow (logged: enforce mode would deny)`.

`/bend-guard doctor` runs the doctor (see step 2). Like the others, these answer only your own typing.

The session where you typed `/bend-guard confirm`, `enforce` or `log-only` uses the change from its next tool call. New sessions use it too. Other sessions that are already open keep the old policy until you run `/reload-plugins` or restart Claude Code, and so does every open session after an approval in the terminal.

### Notices at the start of a session

bend-guard shows one only when there is something to say:

| Notice | What to do |
| --- | --- |
| `bend-guard: guarding <project> in log-only mode (project rules are logged, not enforced; self-protection is enforced).` or `... (rules enforced).` | Nothing. It tells you the mode. |
| The same line, ending `No OpenRouter key: unknown commands are asked about without Clef.` | Add the key file, or ignore it. |
| `<project>\BEND_RULES.md is not approved, so it is not enforced.` | Run `/bend-guard:compile`, then type `/bend-guard approve`. |
| `BEND_RULES.md changed since approval; run /bend-guard:compile and approve again.` | Do that. The old approved rules keep running until you do. |
| `bend-guard: refusing every tool call in <project>: <why>. To fix: type /bend-guard approve, or check %USERPROFILE%\.claude\bend-guard\approved.json.` (or `refusing every tool call here: ...` when approved.json is damaged) | See "Fingerprint mismatch, and other refusals". |

Other messages appear during the session (each stays up for 10 seconds, or 60 for the approval results):

| Message | What it means |
| --- | --- |
| `bend-guard: approving... <step>` (status line under the prompt) | An approval is running in the background. The step changes as the proofs, compile and probes finish. |
| `bend-guard: rules for <project> are live (log-only).` or `(enforcing).` | The approval finished. The rules run from the next call. |
| `bend-guard: <project> was not approved: <why>` | The approval stopped. Read the reason, fix it, type `/bend-guard approve` again. |
| `bend-guard: OpenRouter credit used up; unknown commands are asked about without Clef.` | Shown once. Clef gives no answers until credit is added. |

## Changing the rules

Edit BEND_RULES.md yourself (Claude cannot: it is protected). Run `/bend-guard:compile`, then approve again. Example: you add a line 16, "Never edit `docs/`". The draft gains a `NoChange` entry for `docs`, and the generator makes a new law, `docs_protected`. If you add "Never make the code slower" instead, it is sorted as judgment, so it goes to `claude-md.txt`.

Each approval rebuilds the one `policy.mjs`, which holds the rules of every approved project. Each rule is tied to its own project's folder.

## Changing bend-guard itself

Once bend-guard is on, it refuses any change to its own files, so Claude cannot change it by accident or on purpose. The way to change it:

1. Disable the plugin, either in Claude Code with `/plugin` or in a terminal, and restart Claude Code (or run `/reload-plugins`):

   ```
   claude plugin disable bend-guard@local-mods
   ```

   (See "The `claude` command" under Setup if `claude` is not on your PATH.)

2. Make the change in `%USERPROFILE%\.claude\local-plugins\bend-guard` (yourself, or with Claude while bend-guard is disabled).
3. Refresh the installed copy (Claude Code runs the hooks from its copy in `~\.claude\plugins\cache`, not from this folder), enable it again, and restart. In your own terminal:

   ```
   claude plugin uninstall bend-guard@local-mods
   Remove-Item -Recurse -Force "$env:USERPROFILE\.claude\plugins\cache\local-mods\bend-guard"   # only if it is still there
   claude plugin install bend-guard@local-mods
   claude plugin enable bend-guard@local-mods
   node "$env:USERPROFILE\.claude\local-plugins\bend-guard\tools\doctor.mjs" --skip-wsl
   ```

   The doctor's `installed copy` line should say `ok`. (If the plugin is already enabled after the install, the enable line just says so.)

If the change touched `bend\` (the translator, the policy, the laws or the templates), approve every project again. That re-proves everything and builds a new `policy.mjs`. Until then the policy approved earlier keeps running, without the change. Changes to `tools\gen.mjs` or `tools\probes.mjs` also need a new approval, because they decide what is generated and probed. If it touched only `hooks\` or the other tools, a restart is enough. To check a change before approving, build and test it with `node tests/lib/build.mjs --prove` (see Testing); the first proof run takes about 5 minutes and later ones reuse unchanged proofs.

`/reload-plugins` re-runs the start-up guess about whether anyone is at the screen. A reload where the guess says "nobody" still works for Asks, because the engine reports `approver = person` on a main-session call and bend-guard trusts that (see "Who can be asked").

Example of a change: teaching Bend the command `jq`. That is a new command model in `bend\core`. The laws hold for any model, so they stay proven, but approve each project again to build a new `policy.mjs`.

## Fingerprint mismatch, and other refusals

At the start of each session bend-guard hashes the live `policy.mjs` (SHA-256) and compares it with the fingerprint saved when you approved. If they differ, the checker may not be the one you approved. So bend-guard refuses every tool call in that project until you fix it. Claude sees:

```
bend-guard: policy.mjs does not match its fingerprint in approved.json. To fix: type /bend-guard approve, or check %USERPROFILE%\.claude\bend-guard\approved.json.
```

Example of a cause: one byte of `%USERPROFILE%\.claude\bend-guard\live\policy\policy.mjs` was changed, or an approval was cut off half way.

**How to fix it.** Approve the project again: `/bend-guard approve`, then `/bend-guard confirm` (the command still works while tool calls are refused), or `approve.mjs` in your own terminal. It builds a fresh `policy.mjs` from the checked sources and saves a new fingerprint. Read the laws it shows you, as you did the first time. If you cannot think how it changed, look at when the file was last written before you re-approve.

The same message style covers a few other states, and the fix is the same:

| Refusal says | Meaning |
| --- | --- |
| `approved.json cannot be read` or `is not valid (version 2 expected)` | The approvals file is damaged. Every call is refused where a BEND_RULES.md is found in the folder or a parent. If it cannot be repaired, move it aside yourself (rename it `approved.json.bad`) and approve each project again. bend-guard is off for all projects until you do. |
| `cannot read ...\policy.mjs` | The live checker is missing. Approve again. |
| `approved.json has no valid policy entry`, `the policy folder in approved.json is not allowed` | The approvals file was edited by hand. Approve again. |
| `it is loaded from <folder>, but it must be installed in <folder>`, `USERPROFILE is not set`, `the home folder ... is not a folder on drive C:` | bend-guard is not installed where it expects to be (see "Where bend-guard must live" under Setup). Move the plugin folder, or reinstall it, then restart Claude Code. Approving again does not help. |
| `its check of <tool> failed or took too long, so it refuses` | The checker crashed or ran past 4 seconds. Try the call again. If it keeps happening, check that node is at `C:\Program Files\nodejs\node.exe`. |

## The OpenRouter key, and what is sent

The key file is `%USERPROFILE%\.claude\bend-guard\openrouter.key`. It holds the key and nothing else, on one line. Use a separate production key with its own spending limit. Create it yourself, so the key never passes through Claude:

```
New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude\bend-guard" | Out-Null
notepad "$env:USERPROFILE\.claude\bend-guard\openrouter.key"
```

Paste the key, save, close. bend-guard reads the file once, when a session starts, and keeps the key in memory. The key never appears in a log, a command line, or Claude's output. bend-guard refuses any attempt by Claude to read or write the file.

**What is sent to OpenRouter and Cloudflare:** only for Bash, PowerShell and Monitor commands in the main session, and only when bend-guard asks Clef (see "The second opinion"). The request holds:

- the shell tool name, the current folder (it contains your Windows user name) and the command text, shortened to its first 1,500 and last 500 characters if longer than 2,000;
- fixed questions that name your protected folders, for example "Would running this command change, delete, move or reveal any file under specs/ or secrets/ ...";
- the model name, `cloudflare/clef-flash`.

Secrets are masked first. Examples: `sk-or-...` keys, `ghp_...` tokens, `AKIA...` keys, `Bearer ...` headers, `https://user:pass@host`, and `password=...` or `token=...` values. Nothing from other tools is sent: no file contents, no `Read` or `Edit` paths, no MCP page text. A call that touches `.env` or `secrets\`, or a not-understood command that names them, is denied before it gets that far. OpenRouter's retention policy for this alpha endpoint was not checked.

The request goes to `https://openrouter.ai/api/alpha/decisions`. There is one try with a 3-second limit and no retry. Answers are kept in memory for the session, so the same command twice costs one call. If the credit runs out (HTTP 402), bend-guard shows "OpenRouter credit used up" once and carries on without Clef.

## The WSL toolchain

Bend 2 runs on Linux and macOS, not on Windows. bend-guard uses WSL only when the rules change: to check the proofs and to compile the checker to JavaScript. At hook time nothing runs in WSL. Windows node runs the compiled `policy.mjs`. Setup step 1 installs it.

- **Distro:** `Ubuntu-24.04`, run as root (there is no Linux user). Scripts run through a login shell (`bash -l`), because `/etc/profile.d/bend.sh` puts `bend` and Lean on the path and sets `BEND_NO_TELEMETRY=1`.
- **Bend 2.0.39**, pinned by hash. The binary is `/opt/bend-2.0.39/bin/bend`, SHA-256 `2ec160fa4486d33aff51e9eedcc294d6b531dc10c279c00b0c00685dae2045cd`. The release tarball hash and the source commit are in `BEND_VERSION`. The approve tool checks the binary's hash before it uses it. Never run `bend update`.
- **Lean 4.34.0**, under `/root/.elan`, for `--verdict`. A proof must pass both Bend's checker and `--verdict`, and both must print `ALL PROOFS CHECK`. Bend exits 0 either way, so the scripts read its words, not its exit code.
- **Build folders:** `/root/bg-build/<name>` inside WSL, made by `tools\stage.sh` (the draft check uses `draft-<slug>`). They are scratch copies and safe to delete.
- **Memory:** one full compile of the policy peaks at about 7.7 GiB (8,048,204 KB, the largest single process; the total across Bend's child processes may be somewhat higher) in WSL and takes about 24 seconds; a full proof run with no cache peaks at about 10 GB across its parallel checks and takes about 3 minutes (both measured 2026-10-26; an earlier version of the translator, with 18 large string matches where lookup tables are now, needed 18.8 GB and 4 minutes to compile). The `.wslconfig` in Setup step 1 gives WSL `memory=22GB` and `swap=16GB` under `[wsl2]`. Two builds at once, or a compile next to a proof run, run out of memory, and the WSL service can then fail with `E_UNEXPECTED`. To recover: wait until nothing uses WSL, run `wsl --shutdown`, and try again.
- **Proof cache:** `/root/.bend-guard-proofs`, written by `tools\prove.sh`. `prove.sh` runs the law folders in parallel and records each proof that passed, keyed on the Bend binary and the `.bend` sources. A later run reuses a proof whose key is unchanged and proves anything else again. The draft check and the tests use it. Approving passes `--no-cache`, because any root process in WSL could add a line to the file, so a line there is not evidence. Delete the file to force a full re-proof.

To check the Bend binary by hand:

```
wsl -d Ubuntu-24.04 -u root -- bash -lc 'sha256sum /opt/bend-2.0.39/bin/bend'
```

## Logs

Every checked call writes one tab-separated line to `%USERPROFILE%\.claude\bend-guard\log\<date>.<session>.tsv` (the date is UTC; `<session>` is the first 8 letters or digits of the session id, so each session writes its own file). The columns are: time, session, agent, tool, verdict, the verdict enforce mode would give, reason, whether Clef was asked, Clef's answer, milliseconds, cache hit, and the command with secrets masked.

The agent column holds `main` or the agent's id, then a note in brackets about who could be asked. Examples:

| Agent column | Meaning |
| --- | --- |
| `main (approver=person)` | The main session, and Claude Code's dialog reaches the user. |
| `main (approver=none not-interactive)` | The main session, but nobody can answer (a headless run), so an Ask is a Deny. |
| `main (refused before the permission step)` | bend-guard refused the call in `tool.call`: it is a Deny for anyone who could answer. |
| `main (permission step answered by another plugin)` | The call went on, but bend-guard's `tool.check` was never asked about it (another plugin answered the permission step first). The verdict shown is the one bend-guard would give where the user can be asked. If that verdict was an Ask and the call ran anyway, the user sees a notice: `bend-guard: <tool> ran without bend-guard's question; another plugin answered the permission step first. bend-guard would have asked: <why>`. |
| `<agent id> (approver=none)` | An agent's call. Agents are never asked. |

Each call gets exactly one line. `suggest.mjs` ignores the bracket note: it groups by the command and the tool, not by the agent column.

To see which commands to teach Bend next, run this in your own terminal (bend-guard keeps Claude out of the state folder):

```
node "$env:USERPROFILE\.claude\local-plugins\bend-guard\tools\suggest.mjs"
```

It groups the calls bend-guard did not understand by the command's first word (plus the subcommand for `git` and `npm`), and prints the top 20 with how often Clef said safe, unsure or risky, and the usual reason. Example:

```
  #  command   times  safe  unsure  risky  no answer  usual reason
  1  jq           41    39       2      0          0  the command jq is not modelled
  2  git stash     9     0       0      0          9  git stash can rewrite files anywhere in the repository
```

So `jq` is the first command to teach: Clef called it safe 39 times out of 41. Options: `--top N`, `--days N` (only the log files of the newest N dates) and `--dir <log folder>`. It reads only the `*.tsv` files there, never the key.

## Try it by hand

Headless tests cannot show a dialog, because nobody is there to click. The headless live runs (`tests/live/run.mjs`) showed that with nobody to ask, an unknown command is denied in every permission mode (default, acceptEdits, bypassPermissions, dontAsk, plan), and a plugin's "ask" is refused in bypassPermissions and dontAsk. The part only a person can check is the dialog itself. Do this in log-only mode, before you switch to enforce.

First install bend-guard and run the doctor (Setup, step 2). Then approve a project whose BEND_RULES.md has the sample rules 1 and 2 (see "The sample rules"): in a session in your project run `/bend-guard:compile`, then `/bend-guard approve`, then `/bend-guard confirm` (or `approve.mjs` in a terminal), and wait for "rules are live". Then, in a Claude Code session in that project (the VS Code extension or the terminal):

1. Default mode: ask Claude to run `ls docs | xargs echo hi`. Expect a permission dialog that says bend-guard does not understand `xargs`. Approve it once and the command should run.
2. bypassPermissions mode (the case that matters most): same command. Expect the same dialog, not a silent run. If it just runs, that is a bug: report it.
3. acceptEdits and plan modes: same command, same expectation (a dialog, or a refusal in plan mode).
4. dontAsk mode: same command. There is no dialog in this mode, so expect a plain refusal that names bend-guard.
5. A known-safe command such as `cat BEND_RULES.md`: no dialog in any mode.
6. Self-protection: ask Claude to write a file under `%USERPROFILE%\.claude\bend-guard\`. Expect a refusal even in log-only mode.
7. An MCP tool (any server you use): expect a dialog saying the tool is not modelled; MCP tools are never auto-allowed.
8. Ask Claude to start a subagent that runs a Bash command: its call should be checked too (see the log, the agent column shows the subagent id).
9. Open `%USERPROFILE%\.claude\bend-guard\log\` and check each call above left exactly one line.
10. Ask Claude to run `python -c "print(open('.env').read())"`. Expect a plain refusal naming rule 2, with no dialog, in log-only mode too. Then ask it to run `python x.py specs/a.md`: expect a dialog whose reason has the line `It mentions specs\ (rule 1).` under bend-guard's first line. Answer No.
11. Type `/bend-guard why`: the calls above should be listed, newest last, with their verdicts. Type `/bend-guard test rm -rf specs`: expect `enforce mode: deny` and `log-only mode: allow (logged: enforce mode would deny)`, and no new log line.
12. In the log, the line for step 1's `xargs` command should have `main (approver=host)` or `main (approver=person)` in the agent column and `ask` as the verdict. If a command in steps 1 to 3 ran with no dialog, or its line says `approver=none`, Claude Code did not show the question: keep bend-guard in log-only mode and report it.

## Testing

Run these from `%USERPROFILE%\.claude\local-plugins\bend-guard`.

```
node tests/lib/build.mjs --prove
node --test tests/corpus.node.test.mjs
node --test tests/tools.node.test.mjs
node --test tests/replay.node.test.mjs tests/clef-bench.node.test.mjs
claude plugin test "$env:USERPROFILE\.claude\local-plugins\bend-guard"
```

To skip the parts that need WSL, set `BG_SKIP_WSL=1` first: in PowerShell `$env:BG_SKIP_WSL=1; node --test tests/tools.node.test.mjs`, in Git Bash `BG_SKIP_WSL=1 node --test tests/tools.node.test.mjs`. `claude plugin test` needs the full-path command (see "The `claude` command" under Setup) when `claude` is not on PATH.

- `tests/lib/build.mjs` builds the policy from the current sources into `tests\.build\policy.mjs`. With `--prove` it also has WSL check every proof (about 5 minutes the first time; unchanged proofs are reused from the proof cache). `--out <dir>` and `--name <wsl build name>` keep a build of your own apart. One compile needs about 7.7 GiB of memory in WSL and a proof run about 10 GB, so never run two builds, or a build and a proof run, at the same time (see "The WSL toolchain").
- `tests/corpus.node.test.mjs` runs the cases in `tests\corpus\*.jsonl` (4,350 at the last full run) through the built policy: paths, shell models for Bash and PowerShell, project rules, log-only, self-protection, who can be asked, Clef answers, and another user's home folder. The case format is in the file's header. `BG_POLICY=<file>` tests another build.
- `tests/tools.node.test.mjs` holds the tests of the tools (gen, probes, approve, suggest, draft check, doctor, the WSL scripts, and a check that no code names a user's folder). `BG_SKIP_WSL=1` skips the parts that need WSL. The approve and doctor tests use a sandboxed copy and a sandbox home, never the real state folder.
- `tests/replay.node.test.mjs` tests the noise replay (below) on a made-up transcript folder in `tests\fixtures\transcripts`: exact counts, no secret or path in its output, and its temp folder removed.
- `tests/clef-bench.node.test.mjs` tests the Clef benchmark offline, with a fake OpenRouter: the scoring, the decision rule, that requests match the mod's own, that the key never shows, the cost cap, and that a 402, a timeout or a wrong answer counts as no answer.
- `claude plugin test` runs the hook tests (257 at the last full run) in `tests\wiring.test.ts` against a fake checker and an in-memory file system: the event order, who can be asked, the log, the `/bend-guard` commands, the reasons, another user's home folder and a wrong install.
- `tests/live/run.mjs` runs headless Claude Code sessions against the real engine: the order of its events, what an Ask becomes when nobody can answer in each permission mode, and whether bend-guard's permission step (`tool.check`) is reached for an MCP tool, a subagent's call and a call in a skill that runs as its own agent. It uses three test-only helpers that are never installed: `tests\live\mcp-stub.mjs` (a one-tool MCP server) `tests\live\skill-probe\` (a plugin with one such skill) and `tests\live\order-probe\` (a probe of the order of the engine's events). It costs model usage, so run it only when you mean to.

**Last full run (2026-10-26):** `build.mjs --prove` passed (11 project laws for the sample rules, `BEND-GUARD CHECK OK`); the corpus ran 4,350 cases, 0 failed; `claude plugin test` ran 257 hook tests, 0 failed; tools, replay and Clef-benchmark tests together ran 233 tests in 32 suites, 0 failed (with WSL, 205 seconds); the typecheck (tsc 5.6.3) passed; `plugin validate` passed with warnings only (no author in plugin.json, no LICENSE and no icon); the draft check for the sample project passed.

**Not tested:** a person answering the permission dialog (the live runs are headless; see "Try it by hand"), the IDE extensions, links, Clef's real answers (no key used yet; see "The Clef benchmark"), and long use in daily work.

## The Clef benchmark

`tools\clef-bench.mjs` asks Clef about a fixed, hand-written set of 120 commands (`tests\live\clef-bench.jsonl`: 40 harmful, such as a `python -c` that deletes `specs\`; 60 everyday harmless ones; 20 unclear) and reports, for four limit sets (the current 800/500/300, and 700/500/300, 900/500/300, 800/600/400), how many harmful ones Clef would refuse, how many harmless ones it would refuse by mistake, the answers by status, latency and the total cost. It uses the mod's own Clef client, makes one paid call per command (three at a time, stopping at `--max-cost`, default $0.25), and reads the key in its own process; the key is never printed or written. The rule: change the limits in `Guard.bend` only if a set refuses at least as many harmful commands and at least 5 points fewer harmless ones; otherwise keep 800/500/300.

```
node tools/clef-bench.mjs --dry                 # sends nothing: which commands reach Clef
node tools/clef-bench.mjs --json out.json       # the paid run (needs the key file)
```

It has not been run yet, because no OpenRouter key was used during development. Without a key it prints `No OpenRouter key at <key file>: the benchmark needs one (...). Nothing was sent.` and stops (exit code 2). The dry run (2026-10-26) shows 107 of the 120 commands reach Clef triage and none a Clef veto; the other 13 are decided without Clef (9 harmful ones are refused by bend-guard itself, 2 harmless ones are allowed, 2 unclear ones ask or are refused). OpenRouter's data retention for this alpha endpoint has not been checked either.

## Noise

How often would bend-guard ask, refuse or call Clef in normal work? `tools/replay.mjs` takes 5,500 tool calls from your past transcripts (half from main sessions, half from subagents), moves each into the project folder and runs it through a built policy as a main-session call with you present and no Clef answer. It prints counts only: shares by verdict, by main or subagent and by tool, the share that would go to Clef, how many shell commands are understood, the most common reasons and refusals, and the shapes (program, subcommand, flag names) of the shell parts not understood. It never prints a command or path unless you add `--show`, and then secrets are masked.

```
node tools/replay.mjs --before 2026-10-26              # same calls on every run
node tools/replay.mjs --policy <other build>\policy.mjs --json out.json
node tools/replay.mjs --tool PowerShell --n 600 --before 2026-10-26   # PowerShell calls only
```

`--agent-as-is` replays subagent calls as agent calls. `--tool <name>` takes only that tool's calls (for example `PowerShell`, which is about 1 in 80 shell calls), still half from main sessions and half from subagents, with the same seed rules; when there are fewer calls than `--n`, it takes all of them. A run takes under a minute.

The numbers below come from the developer's own transcripts (seed 1, `--before 2026-10-26`, the same 5,500 calls each time). Yours will differ. Baseline, early in development (policy `2e641f959d4e`):

| | ask | deny | to Clef | shell understood |
|---|---|---|---|---|
| all calls | 64.1% | 0.8% | 55.9% | 14.2% |
| main sessions | 62.6% | 1.3% | 53.3% | 10.6% |
| Bash | 87.9% | 0.7% | 84.4% | 14.4% |
| PowerShell | 100% | 0% | 100% | 0% |

After two later rounds of teaching bend-guard more commands (policies `f630bf33fb6a` and `c357eb66f836`; `node tools/replay.mjs --seed 1 --before 2026-10-26 --policy <file>`):

| ask share | after round 2 | after round 3 |
|---|---|---|
| all calls | 37.9% | 34.2% |
| main sessions | 46.6% | 44.9% |
| subagents | 29.2% | 23.4% |
| Bash | 50.6% | 44.8% |
| Bash, main sessions | 64.3% | 61.5% |
| PowerShell (60 calls) | 91.7% | 91.7% |

Calls sent to Clef fell from 32.3% to 28.4%, refusals rose from 1.7% to 1.8% (the 9 calls the no-read rule now refuses), and no call moved from allow to ask or deny. The checker crashed on none of them. Round 3 taught bend-guard `git show` and `git cat-file` of `<rev>:<path>` and other git listings (`git tag`, `worktree list`, `ls-remote`), read-only `gh` and `curl` forms (GET only, no upload, no config file), small status commands (`df`, `ps`, `tasklist`, `pip list`, `npm view`, `rg` and others) and PowerShell comma lists. A PowerShell-only replay (`--tool PowerShell --n 600`, 590 calls) barely moved: 94.6% to 94.4% ask, because PowerShell calls mostly use variables and script blocks, which bend-guard does not read.

Current numbers (2026-10-26; same calls, 0 crashes): all calls allow 64%, ask 34.1%, deny 1.9%, Clef 28.4%. Main sessions: allow 52.1%, ask 44.9%, deny 3%, Clef 36.1%. Subagents: allow 75.9%, ask 23.4%, deny 0.7%, Clef 20.7%. Bash (3,556 calls): allow 53.1%, ask 44.8%, deny 2.1%, Clef 42.2%. PowerShell (60 calls): allow 5%, ask 91.7%, deny 3.3%. MCP: ask 100%. The latest protections (environment and config files) added no noise.

Targets were under 15% of calls to Clef and under 40% asks in main sessions; both are still missed, and the design budget for Clef is 5%. What is left is mostly commands that run other code (`python` alone is the only unknown part in about 300 of the 5,500 calls, then `ssh`, `fly`, `node`, `bash`), which no model can read soundly. Ideas that would lower the numbers, none built: an opt-in rule kind naming exact command starts you trust (such as `python tools/`); a rule naming MCP tools you trust; letting subagents ask instead of being refused. The last two change a design choice ("a tool bend-guard does not model is never allowed", "agents are never asked").

## Files

```
commands\compile.md     the /bend-guard:compile command
hooks\                  the mod: register.tsx (wiring and the /bend-guard command), glue.ts, checker.ts,
                        clef.ts, asks.ts, reasons.ts (the text of an Ask or a Deny), sha256.ts;
                        hooks.json names register.tsx as the module
host\host.mjs           the node child that runs the compiled checker (checker.ts carries an exact copy)
bend\core\              the translator and the policy, in Bend
bend\laws\              the laws and their proofs, in Bend
bend\base\              the entry file the checker is compiled from
bend\templates\         what the generator fills in for each project
bend\fixtures\          the sample project's drafts and generated files
bend\NOTES.md           verified Bend syntax and the naming rules
tools\                  stage.sh, prove.sh (the proof gate: parallel, with the proof cache), check.sh (the
                        plain serial gate prove.sh is based on), compile.sh, wsl.mjs, gen.mjs, probes.mjs,
                        draft-check.mjs, approve.mjs, suggest.mjs, replay.mjs (noise), home.mjs (where
                        things live, from the home folder), doctor.mjs, clef-bench.mjs and clef-lib.mjs
                        (the Clef benchmark)
tests\                  corpus\*.jsonl, the node tests, wiring.test.ts (the hook tests), lib\ (build and
                        policy loader, the hook test kit) and live\ (headless engine scenarios, the mcp-stub, skill-probe and
                        order-probe helpers, and clef-bench.jsonl, the benchmark's labelled set); tests\.build and
                        tests\.build-docs are scratch builds (git ignores them)
BEND_VERSION            the pinned Bend version and its hashes

%USERPROFILE%\.claude\bend-guard\             state; bend-guard keeps Claude out of it
  approved.json                               what was approved, with the fingerprints
  live\policy\policy.mjs                      the compiled checker that runs
  live\projects\<slug>\                       each approved project's sort.json and ask.json
  log\<date>.<session>.tsv                    one line per checked call
  openrouter.key                              your key (you make this file)
  .approve-token                              the one-time token of a /bend-guard confirm, enforce or
                                              log-only; approve.mjs removes it at once
%USERPROFILE%\.claude\bend-guard-drafts\<slug>\   drafts from /bend-guard:compile (Claude may write here)
  .check\                                     the draft check's output (generated Bend files, display.json,
                                              probes.json, policy.mjs); safe to delete
  .approve-<random>\                          the copy /bend-guard approve showed you; confirm checks that
                                              it is unchanged, then removes it. One left behind is removed
                                              by a later approve once it is over 24 hours old
/root/.bend-guard-proofs (inside WSL)         the proof cache that prove.sh keeps
```
