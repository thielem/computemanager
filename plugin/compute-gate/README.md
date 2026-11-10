# compute-gate (Claude Code plugin)

Hooks + skill that route heavy agent commands through Compute Manager's gate.

| Part | What it does |
|---|---|
| `hooks/hooks.json` | `PreToolUse` `"*"` → `cgate hook`: denies heavy Bash commands not run via `cgate` with the exact line to use instead (`cgate run --max <estimate> -- '<cmd>'`, background), delivers pending stop / slot-ready notices once (deny). Never rewrites commands, never answers "allow"; app unreachable → no output |
| `skills/compute-gate` | Primary mechanism: agents run heavy work via `cgate run --max … -- '…'` in the background, wait for tickets, obey stop notices |

## Install

1. Build and put `cgate` on `PATH` (hooks and wrapped commands call it by name):
   ```sh
   scripts/swiftw build -c release --product cgate
   ln -sf "$PWD/.build/release/cgate" ~/.local/bin/cgate
   ```
2. Load the plugin, either
   - for one session: `claude --plugin-dir /path/to/computemanager/plugin/compute-gate`, or
   - permanently: add a local marketplace that lists this directory, then
     `claude plugin install compute-gate@<marketplace>` (user scope).
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
