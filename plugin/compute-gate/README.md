# compute-gate (Claude Code plugin)

Hooks + skill that route heavy agent commands through Compute Manager's gate.

| Part | What it does |
|---|---|
| `hooks/hooks.json` | `PreToolUse` `"*"` → `cgate hook`: denies heavy Bash commands not run via `cgate` with the exact line to use instead (`cgate run --max <estimate> -- '<cmd>'`, background), delivers pending stop / slot-ready notices once (deny). Never rewrites commands, never answers "allow"; app unreachable → no output |
| `skills/compute-gate` | Primary mechanism: agents run heavy work via `cgate run --max … -- '…'` in the background, wait for tickets, obey stop notices |

## Install

1. Get `cgate`: the Homebrew cask links it (`brew install --cask thielem/tap/compute-manager`),
   or from a checkout `scripts/install-cgate.sh` puts it in `~/.local/bin`. The hook looks in
   `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, then `PATH`; silent if missing.
2. Add the marketplace and install the plugin:
   ```sh
   claude plugin marketplace add thielem/computemanager
   claude plugin install compute-gate@computemanager
   ```
3. Start ComputeManager.app. Without it, `cgate` fails open (commands run ungated and are
   logged to `~/Library/Logs/ComputeManager/cgate-fallback.log`).

## Heavy-command matching

Patterns come from the app settings (default `Defaults.autoWrapPatterns`). The command is split at
`&&`, `||`, `;`, `|`, `&`, newlines and parentheses (outside quotes; heredoc bodies skipped). Per
segment, prefixes are stripped layer by layer and each layer is tried: `VAR=value`,
`time`/`env`/`nohup`/`exec`/`command`, `timeout N`, `bash`/`sh`/`zsh` (script path matched,
`-c '<line>'` matched as a line), `uv run [--flags]`, `python[3] -m`, `npx`, `pnpm exec`. A
pattern matches when its words equal the segment's first words; the first word also matches by
basename (`check.sh` ↔ `./scripts/check.sh`, `make` ↔ `/usr/bin/make`, not `cmake`). A line that
is exactly one `cgate …` invocation is never denied; mixed lines (`cgate status; swift test`) are
treated like any other.

## cgate run

- `cgate run --max 10m -- 'cd x && make'`: one argument = shell line, run via `$SHELL -c`
  (`$SHELL` if bash/zsh/sh, else `/bin/bash`); `cgate run -- make -j8`: several arguments = argv.
- A `cd` inside the wrapped line does not persist in the agent's shell.
- Session: `CLAUDE_CODE_SESSION_ID`, else `~/.claude/sessions/<pid>.json` of an ancestor process.
