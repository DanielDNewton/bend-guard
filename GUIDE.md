# bend-guard: user guide

For anyone setting up and using bend-guard on their own PC. Written 2026-10-26.

The plugin's README (`%USERPROFILE%\.claude\local-plugins\bend-guard\README.md`) has every detail. This guide covers what you need to get running and to use it day to day.

**Download:** `git clone https://github.com/DanielDNewton/bend-guard "$env:USERPROFILE\.claude\local-plugins\bend-guard"`. It must be that exact folder (see section 4b).

## 1. What bend-guard is

Agents sometimes ignore a rules list. bend-guard is a Claude Code plugin that makes the hard rules impossible for Claude to break.

You write your project's rules in plain English in a file called `BEND_RULES.md`, in the project folder. For example:

```
1. Never delete or edit files in `specs/`.
5. Never run `git push --force` or `git push -f`.
```

bend-guard turns each hard rule into a checker written in Bend 2. Each rule also gets a *law*: a statement about the checker, with a proof that the machine checks. If any proof fails, the checker is not installed.

Then, before **every** tool call Claude makes in that project, the checker gives one of three answers. Every tool call means file edits, shell commands, MCP tools, subagents and workflow agents.

| Answer | What happens | Example |
| --- | --- | --- |
| Allow | The call runs. | `cat README.md` |
| Ask | You get Claude Code's permission prompt, with bend-guard's reason. | `npm install left-pad` |
| Deny | The call is refused, and Claude is told which rule blocked it. | `rm -rf specs`, or an `Edit` of `specs\a.md` |

When several things apply to one call, the strictest answer wins.

An example: Claude tried to write `specs\project-spec.md` and got back:

> bend-guard rule (BEND_RULES.md): <your project>/specs may not be changed. Leave it as it is, or ask the user to change BEND_RULES.md. (BEND_RULES.md line 1: "Never delete or edit files in `specs/`. …")

## 2. What it protects, and what it doesn't

**It does:**

- **Sees through tricks.** `rm -rf ./SPECS/../specs` is seen as deleting `specs` (it ignores letter case and follows `..`).
- **Never allows what it doesn't understand.** A command it can't read is never allowed on its own, so you're asked. Example: `python -c "import shutil; shutil.rmtree('specs')"`.
- **Turns asks into refusals when nobody can answer.** Subagents and headless runs (`claude -p`) have nobody to ask, so their asks are refused.
- **Protects itself.** It refuses any change to its own code and rules, your `BEND_RULES.md`, Claude Code's settings, shell profiles, git hooks and config, and other files that decide what runs later. This holds in every mode, even if you click yes.
- **Lets Clef only tighten.** Clef is an optional second-opinion model on OpenRouter. It can make an answer stricter but never looser, and that is proven too.

**It doesn't:**

- **Watch what a program does once it starts.** If you approve `npm test`, the test code runs with Claude's full rights. That is why every `npm test`, npm script and `npm install` asks.
- **Check that a law matches what your sentence meant.** If your rule says `spec` instead of `specs`, the wrong folder is protected perfectly. Read every line when you approve.
- **Enforce judgment rules.** "Match the existing code style" can't be checked by machine. Those rules go in `CLAUDE.md`.
- **See symlinks or junctions.** If `docs\latest` links to `specs\`, an edit through `docs\latest` isn't caught.
- **Guard anything outside approved projects.** In other folders it does nothing. Keep other Claude sessions away from `%USERPROFILE%\.claude`.
- **Limit you.** You can still edit anything yourself, outside Claude.

**It asks a lot.** In a replay of real work, about a third of calls asked (45% in main sessions). Most of those were commands that run other code (`python`, `node`, `ssh`) or MCP tools. Every MCP tool asks, by design. The README's "Noise" section lists the options for reducing this.

## 3. What you need

- **Windows**, with your home folder on drive `C:`.
- **Node 22 or newer**, at exactly `C:\Program Files\nodejs\node.exe`.
- **Git**, to download bend-guard.
- **Claude Code 2.1.310.** That's the version the hooks were checked against.
- **WSL with `Ubuntu-24.04`, Bend 2.0.39 and Lean 4.34.0.** These are only used when rules change, to check proofs and compile. Nothing runs in WSL during normal tool calls.
- **At least 12 GB of memory for WSL** (RAM plus swap). One compile peaks near 7.7 GiB, and a proof run peaks near 10 GB.
- **An OpenRouter key** (optional, but recommended). Without it, every command that would go to Clef asks you instead.

## 4. Install

### 4a. Set up WSL (once)

1. In an administrator PowerShell, run the command below. Restart if asked, and let the distro finish its first start.

   ```
   wsl --install -d Ubuntu-24.04
   ```

2. Create `%USERPROFILE%\.wslconfig` with the lines below, then run `wsl --shutdown`.

   ```
   [wsl2]
   memory=22GB
   swap=16GB
   ```

3. In the distro, as root, download the Bend 2.0.39 Linux x64 tarball. The plugin's `BEND_VERSION` file has its address and hash. Check both hashes:

   ```
   sha256sum <the tarball>                  # must equal the tarball hash in BEND_VERSION
   mkdir -p /opt/bend-2.0.39 && tar -xzf <the tarball> -C /opt/bend-2.0.39
   sha256sum /opt/bend-2.0.39/bin/bend      # must be 2ec160fa4486d33aff51e9eedcc294d6b531dc10c279c00b0c00685dae2045cd
   ```

4. Install Lean as root:

   ```
   curl https://elan.lean-lang.org/elan-init.sh -sSf | sh -s -- -y --default-toolchain leanprover/lean4:v4.34.0
   ```

5. Create `/etc/profile.d/bend.sh` with these lines:

   ```
   export PATH=/opt/bend-2.0.39/bin:/root/.elan/bin:$PATH
   export BEND_NO_TELEMETRY=1
   ```

6. Check that both tools run:

   ```
   wsl -d Ubuntu-24.04 -u root -- bash -lc 'bend --version && lean --version'
   ```

**Never run `bend update`.** The approval step checks Bend's exact hash.

### 4b. Install the plugin

bend-guard must sit at exactly `%USERPROFILE%\.claude\local-plugins\bend-guard`, or it refuses to work. So a plain `claude plugin marketplace add` of the GitHub repository won't work. Clone it into that folder and install it from a local marketplace instead.

1. Download it, in your own PowerShell:

   ```
   git clone https://github.com/DanielDNewton/bend-guard "$env:USERPROFILE\.claude\local-plugins\bend-guard"
   ```

2. Create the marketplace file `%USERPROFILE%\.claude\local-plugins\.claude-plugin\marketplace.json`:

   ```
   New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude\local-plugins\.claude-plugin" | Out-Null
   notepad "$env:USERPROFILE\.claude\local-plugins\.claude-plugin\marketplace.json"
   ```

   If you don't have one yet, paste this whole file (put your own name or handle in `owner`):

   ```json
   {
     "name": "local-mods",
     "owner": { "name": "your-name" },
     "plugins": [
       { "name": "bend-guard", "source": "./bend-guard" }
     ]
   }
   ```

   If you already have one, add `{ "name": "bend-guard", "source": "./bend-guard" }` under `"plugins"`. Any marketplace name works; if yours isn't `local-mods`, use `bend-guard@<its name>` in the commands below.

   Edit this file before you turn bend-guard on. After that, bend-guard refuses Claude's changes in that folder.

3. Register the marketplace, then install and enable the plugin:

   ```
   claude plugin marketplace add "$env:USERPROFILE\.claude\local-plugins"
   claude plugin install bend-guard@local-mods
   claude plugin enable bend-guard@local-mods
   ```

   If `claude` isn't on your PATH, use the copy inside the VS Code extension, or run `/plugin` inside Claude Code instead.

4. Restart Claude Code, or run `/reload-plugins`.
5. Run the doctor in your own terminal and fix every `PROBLEM` line it prints. It only reads, and makes no network calls.

   ```
   node $env:USERPROFILE\.claude\local-plugins\bend-guard\tools\doctor.mjs
   ```

   Before your first approval, it reports that `approved.json` doesn't exist. That's expected.

**Updating.** In your own terminal:

1. Disable the plugin (`/plugin`, or `claude plugin disable bend-guard@local-mods`) and restart Claude Code.
2. Pull the new version, and list what changed in the policy sources:

   ```
   git -C "$env:USERPROFILE\.claude\local-plugins\bend-guard" pull
   git -C "$env:USERPROFILE\.claude\local-plugins\bend-guard" diff --stat ORIG_HEAD HEAD -- bend tools/gen.mjs tools/probes.mjs
   ```

3. Refresh the installed copy, re-enable it, and check it:

   ```
   claude plugin uninstall bend-guard@local-mods
   Remove-Item -Recurse -Force "$env:USERPROFILE\.claude\plugins\cache\local-mods\bend-guard"   # only if it is still there
   claude plugin install bend-guard@local-mods
   claude plugin enable bend-guard@local-mods
   node $env:USERPROFILE\.claude\local-plugins\bend-guard\tools\doctor.mjs --skip-wsl
   ```

   The doctor's `installed copy` line should say `ok`. Then restart Claude Code.
4. If the `diff` listed any file, approve every project again (section 6). Until you do, your old approved rules keep running without the update's changes.

### 4c. Add the OpenRouter key (optional)

Create the key file yourself, so the key never passes through Claude:

```
New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude\bend-guard" | Out-Null
notepad "$env:USERPROFILE\.claude\bend-guard\openrouter.key"
```

1. Paste the key on one line, then save and close. Use a separate key with its own spending limit.
2. Run `doctor.mjs --clef` once to check the key. It makes one paid call, a fraction of a cent.

Clef is only sent shell commands from the main session, and only when bend-guard asks it. Secrets are masked first. It never sees file contents.

## 5. Write your rules

Create `BEND_RULES.md` in the project folder. Number each rule. Use backticks for paths and commands. The kinds of rule bend-guard can enforce:

| You write | It becomes |
| --- | --- |
| "Never delete or edit files in `specs/`." | No change under that folder. |
| "Never edit `.env` or anything in `secrets/`, and never print their contents." | No reading or changing. |
| "Never run `rm -rf` on anything outside `tmp/`." | Recursive deletes only under `tmp/`. |
| "Never run `git push --force`." | No force push. |
| "Never push directly to `main`." | No push to that branch. |
| "Don't install new npm packages without asking first." | An ask. |
| "Run `npm test` before saying a task is done." | A reminder at the end of Claude's answer. It can't block. |
| "Match the existing code style." | A judgment rule. It goes to `CLAUDE.md`, not the checker. |

## 6. Turn the rules on

All of these steps are yours. bend-guard refuses to let Claude run `approve.mjs` or `/bend-guard`.

1. **Draft.** In a Claude Code session in the project, run `/bend-guard:compile`.
   - Claude sorts each rule as hard, ask or judgment, then the machine checks every proof. The run ends with `BEND-GUARD CHECK OK`.
   - The first run takes about 5 minutes. Later runs reuse unchanged proofs.
   - It also writes `claude-md.txt`, with your judgment rules ready to paste into `CLAUDE.md`.
2. **Review.** Type `/bend-guard approve`. It shows every rule with its kind and its law, and flags any line that looks hard but wasn't sorted as hard (`CHECK THIS`). Read it all.
3. **Confirm.** In the same session, within 30 minutes, type `/bend-guard confirm`.
   - It re-proves everything from scratch in the background, which takes about 5 minutes. A status line under the prompt shows its progress.
   - Keep the session open until you see `rules for <project> are live (log-only)`.
4. **Watch for a few days.** You start in **log-only** mode:
   - Project rules are logged, not enforced.
   - Self-protection is enforced from the start.
   - Commands bend-guard doesn't understand still ask.
5. **Enforce.** When the log looks right, type `/bend-guard enforce`. To go back, type `/bend-guard log-only`.

You can run the same approval in your own PowerShell instead:

```
node $env:USERPROFILE\.claude\local-plugins\bend-guard\tools\approve.mjs <project folder>
```

Sessions that are already open keep the old rules until you run `/reload-plugins`.

## 7. Day to day

| Command | What it does |
| --- | --- |
| `/bend-guard status` | Shows the mode and what's approved. |
| `/bend-guard why [n]` | Lists the last n checked calls (5 by default), with each verdict and the rule line behind it. In log-only mode it shows what enforce mode would have done. |
| `/bend-guard test <command>` | Judges a command without running it, in both modes. For example, `/bend-guard test rm -rf specs` gives `enforce mode: deny`. |
| `/bend-guard doctor` | Runs the install checks. |
| `/bend-guard enforce` / `log-only` | Switches the mode for every approved project. |

**Logs.** Each checked call writes one line to `%USERPROFILE%\.claude\bend-guard\log\<date>.<session>.tsv`. The line holds the tool, the verdict, the verdict enforce mode would give, the reason, Clef's answer and the command, with secrets masked.

**Find the noisiest commands.** Run `node ...\bend-guard\tools\suggest.mjs` in your terminal. It lists the commands bend-guard didn't understand most often, which are the ones worth teaching it next.

**Session notices.** At the start of a session, bend-guard tells you the mode. It also tells you if `BEND_RULES.md` changed since you approved it. If so, run `/bend-guard:compile`, then approve again. Until you do, the old rules keep running.

## 8. Changing things

- **Changing your rules.** Edit `BEND_RULES.md` yourself (Claude can't), then run `/bend-guard:compile`, `/bend-guard approve` and `/bend-guard confirm`.
- **Changing bend-guard's own code:**
  1. Disable the plugin (`/plugin`, or `claude plugin disable bend-guard@local-mods`).
  2. Make the change.
  3. Reinstall, so the installed copy under `%USERPROFILE%\.claude\plugins\cache` is refreshed.
  4. Re-enable the plugin, and check that the doctor's `installed copy` line says `ok`.
  5. If anything under `bend\` changed, approve every project again.

## 9. Turning it off

- **Rules only:** `/bend-guard log-only`. Self-protection stays on, so this isn't fully off.
- **The whole plugin:** `/plugin`, disable bend-guard, then restart. Your approvals are kept.
- **One project:**
  1. Edit `%USERPROFILE%\.claude\bend-guard\approved.json` yourself and delete that project's entry.
  2. Keep the file valid JSON. A broken file makes bend-guard refuse every call in every project that has a `BEND_RULES.md`.
  3. Restart Claude Code.

## 10. When something goes wrong

| You see | Do this |
| --- | --- |
| `policy.mjs does not match its fingerprint` | The live checker isn't the one you approved. Approve again. The `/bend-guard` commands still work while calls are refused. |
| `approved.json cannot be read` / `is not valid` | Repair the file, or rename it to `approved.json.bad` and approve each project again. |
| `it is loaded from <folder>, but it must be installed in <folder>` | The plugin is in the wrong place. Move it or reinstall it. Approving won't help. |
| `its check of <tool> failed or took too long` | The checker crashed or ran past its 4-second limit. Try again. Check that node is at `C:\Program Files\nodejs\node.exe`. |
| WSL fails with `E_UNEXPECTED` during a build | WSL ran out of memory. Make sure only one build runs, run `wsl --shutdown`, then retry. |
| `OpenRouter credit used up` | Add credit. Until then, Clef's calls ask you. |
| A command ran with no dialog when it should have asked | Switch to log-only and report it. That's a bug. |

**Speed.** Each checked call adds about 100 to 200 ms. A call that goes to Clef adds up to 3 seconds more. A check that runs past 4 seconds is refused.

## 11. Where things live

```
%USERPROFILE%\.claude\local-plugins\bend-guard\   the plugin (README, hooks, bend sources, tools, tests)
%USERPROFILE%\.claude\bend-guard\                 state (Claude is kept out of it)
  approved.json                                   what was approved, with fingerprints
  live\policy\policy.mjs                          the compiled checker that runs
  log\                                            one line per checked call
  openrouter.key                                  your key
%USERPROFILE%\.claude\bend-guard-drafts\<slug>\   drafts from /bend-guard:compile
/root/.bend-guard-proofs (in WSL)                 proof cache, used by drafts only (safe to delete)
```

The README in the plugin folder is the full reference. It covers the laws, the known gaps, testing, and the Clef benchmark.

## 12. Known status

As of 2026-10-26:

- Every law is proven by Bend's checker and again by the Lean kernel.
- Tests pass: 4,350 policy cases, 257 hook tests, and 233 tool, replay and Clef-benchmark tests.
- Headless runs against the real Claude Code engine pass in every permission mode.

Not yet done:

- The permission dialog hasn't been tested by a person in daily use. Work through the "Try it by hand" checklist in the README before you switch to enforce.
- Clef's thresholds haven't been tuned, because no OpenRouter key has been used yet.
