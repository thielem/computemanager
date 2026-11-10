# Sourced by check.sh / swiftw. Project-wide build lock: at most 1 build/test run across all
# worktrees of this project. Lock = directory; holder PID recorded inside; stale locks
# (dead holder) are removed.
CM_LOCK=/tmp/computemanager-build.lock

cm_lock() {
  local waited=0
  until mkdir "$CM_LOCK" 2>/dev/null; do
    local holder
    holder=$(cat "$CM_LOCK/pid" 2>/dev/null || true)
    if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null; then
      rm -rf "$CM_LOCK"   # stale: holder is dead
      continue
    fi
    (( waited++ % 15 == 0 )) && echo "build lock held by pid ${holder:-?}; waiting…" >&2
    sleep 2
  done
  echo $$ > "$CM_LOCK/pid"
  trap 'cm_unlock' EXIT
  trap 'exit 130' INT TERM
}

cm_unlock() {
  [[ "$(cat "$CM_LOCK/pid" 2>/dev/null)" == "$$" ]] && rm -rf "$CM_LOCK"
  [[ -n "${CM_LOG:-}" ]] && rm -f "$CM_LOG"
  return 0
}
