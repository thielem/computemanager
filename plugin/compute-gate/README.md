# compute-gate (Claude Code plugin)

Hooks + skill that route heavy agent commands through Compute Manager's gate.

| Part | What it does |
|---|---|
| `hooks/hooks.json` | `PreToolUse` `"*"` → `cgate hook`: wraps matching Bash commands in `cgate run --session <id> -- '<cmd>'` (allow + `updatedInput`), denies when busy/off, delivers pending stop / slot-ready notices once |
| `skills/compute-gate` | Tells agents to run heavy work in the background, wait for tickets, obey stop notices |

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

## Auto-wrap matching

Patterns come from the app settings (default `Defaults.autoWrapPatterns`). The command is split at
`&&`, `||`, `;`, `|`, `&`, newlines and parentheses (outside quotes); per segment, leading
`VAR=value` and `time`/`env`/`nohup`/`exec`/`command` are skipped. A pattern matches when its
words equal the segment's first words; the first word also matches by basename
(`check.sh` ↔ `./scripts/check.sh`, `make` ↔ `/usr/bin/make`, not `cmake`). Commands containing
a `cgate …` segment are never re-wrapped. The whole command line is wrapped as one argument and
run by `cgate run` via `$SHELL -c`.

Note: a wrap answers `permissionDecision: "allow"`, which skips Claude Code's permission prompt
for that (whole) command line.
