# Sourced by check.sh / swiftw. Project-wide build lock: at most 1 build/test run across all
# worktrees of this project. Lock = directory; holder PID recorded inside. Stale locks (dead
# holder, or no pid file after ~10 s) are taken over atomically: rename away, then retry mkdir,
# so two waiters can never both remove a lock and both enter.
CM_LOCK=/tmp/computemanager-build.lock

cm_lock_is_stale() {
  local holder
  holder=$(cat "$CM_LOCK/pid" 2>/dev/null || true)
  if [[ -n "$holder" ]]; then
    ! kill -0 "$holder" 2>/dev/null
    return
  fi
  # No pid file: holder died between mkdir and writing the pid, or is just writing it.
  local mtime now
  mtime=$(stat -f %m "$CM_LOCK" 2>/dev/null) || return 1
  now=$(date +%s)
  (( now - mtime > 10 ))
}

cm_lock() {
  # Re-entrant for children of the holder (release.sh → bundle.sh → swiftw): they share its lock.
  if [[ -n "${CM_LOCK_OWNER:-}" && "$(cat "$CM_LOCK/pid" 2>/dev/null)" == "$CM_LOCK_OWNER" ]]; then
    return 0
  fi
  local waited=0
  until mkdir "$CM_LOCK" 2>/dev/null; do
    if cm_lock_is_stale; then
      local stale="$CM_LOCK.stale.$$"
      mv "$CM_LOCK" "$stale" 2>/dev/null && rm -rf "$stale"
      continue
    fi
    (( waited++ % 15 == 0 )) && echo "build lock held by pid $(cat "$CM_LOCK/pid" 2>/dev/null || echo ?); waiting…" >&2
    sleep 2
  done
  echo $$ > "$CM_LOCK/pid"
  export CM_LOCK_OWNER=$$
  trap 'cm_unlock' EXIT
  trap 'exit 130' INT TERM
}

cm_unlock() {
  [[ "$(cat "$CM_LOCK/pid" 2>/dev/null)" == "$$" ]] && rm -rf "$CM_LOCK"
  [[ -n "${CM_LOG:-}" ]] && rm -f "$CM_LOG"
  return 0
}
