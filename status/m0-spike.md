# M0 spike status

## (a) fanprobe — spikes/fanprobe
- Build: `spikes/fanprobe/build.sh` (swiftc + ad-hoc codesign). Modes: `read` (unprivileged), `keys [prefix]`, `test` (root).
- SMC reads work WITHOUT root (IOServiceOpen + selector 2). SMCParam must be 80 bytes: Swift packs nested structs by size, so SMCKeyInfo needs 3 explicit pad bytes.
- Mac14,9 / macOS 27.0.1: FNum=2, F{0,1}Mn=2317, Mx=6800 (flt), Ac/Tg flt, Md ui8 (0=auto). **No `Ftst` key** — test writes F*Md directly when Ftst is absent.
- Also present: F{n}Dc (flt), Fb, Fc, Sf, St (ui8=5), FOff, FRmp, FOFC.
- Temps (flt): Tp* 54 keys (~80–107 °C under build load), Te* 3, Tg* 10, plus Tf*/Th*/Ts*/TPD*/TRD* etc. 236 plausible T* keys.
- Pending: user runs `sudo /Users/mthiele/Documents/GitHub/computemanager-wt/m0-spike/spikes/fanprobe/fanprobe test` once.

## (b) Messaging socket
- `CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/<claude-pid>.sock` + `_TOKEN` exported to Bash (subagents share the parent session's socket).
- Wire format (NDJSON over UDS): `{"type":"auth","token":"$TOKEN"}\n{"type":"user","message":{"role":"user","content":"..."}}\n` (auth optional on macOS; connection must send a full line within 30 s).
- Tested once via `nc -U`: delivered to the idle parent session as "Another Claude session sent a message". Works.
- Background Bash: `sleep` → `/bin/zsh` (own pgid) → `claude` (pid = socket name). $PPID of Bash = claude pid.
