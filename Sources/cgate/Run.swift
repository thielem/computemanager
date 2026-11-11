import Darwin
import Foundation
import Shared

/// Everything `cgate run` needs from the outside world (injectable for tests).
struct RunContext: Sendable {
    var link: GateLink
    var env: [String: String]
    var cwd: String
    var heartbeatInterval: TimeInterval = Defaults.leaseHeartbeatInterval
    var killGrace: TimeInterval = Defaults.killGrace
    var fallbackLog: String = Paths.cgateFallbackLog
    /// Forward SIGINT/SIGTERM/SIGHUP to the child (real CLI only).
    var forwardSignals = false
    var stderr: @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    static func live() -> RunContext {
        RunContext(link: GateLink(path: Paths.gateSocket), env: ProcessInfo.processInfo.environment,
                   cwd: FileManager.default.currentDirectoryPath, forwardSignals: true)
    }
}

/// `cgate run` (AGENT-1, GATE-5/6/10/11).
///
/// acquire → granted: spawn child in its own process group, heartbeat every
/// `heartbeatInterval`, obey directives (softStop: print notice once; hardStop: SIGTERM pgid,
/// SIGKILL after `killGrace`, exit 77/78; unknownJob: reattach), release on exit, exit with the
/// child's code. busy 75 / off 76 / ticketExpired 79. App unreachable → run ungated and append
/// to the fallback log. A single argument after `--` is a shell line run via `$SHELL -c`
/// (`$SHELL` only if bash/zsh/sh, else /bin/bash); several arguments are an argv, exec'd
/// directly. After the child exits, a killed (hard stop / walltime / killJob) or interrupted
/// run's whole process group gets SIGKILL, so TERM-ignoring grandchildren die too.
/// Forwarded SIGINT/SIGTERM/SIGHUP escalate to SIGKILL after `killGrace`; exit 128 + signal.
enum Runner {
    static func run(_ o: RunOptions, _ ctx: RunContext) -> Int32 {
        let session = o.session ?? SessionLookup.resolve(env: ctx.env)
        let single = o.command.count == 1
        let text = single ? o.command[0] : o.command.map(shellQuote).joined(separator: " ")
        let argv = single ? [shell(ctx.env), "-c", o.command[0]] : o.command
        let acq = AcquireRequest(sessionId: session, cwd: ctx.cwd, command: text, pid: getpid(),
                                 maxRuntimeSeconds: o.maxRuntime, ticket: o.ticket,
                                 autoWrapped: false,  // K1: the hook never wraps
                                 messagingSocket: ctx.env[ClaudeMessaging.socketEnv])

        var job: (id: UUID, max: TimeInterval, startedAt: Date)?
        switch try? ctx.link.call(.acquire(acq)) {
        case .acquire(.granted(let id, let max))?:
            job = (id, max, Date())
        case .acquire(.busy(let t))?:
            ctx.stderr(CgateMessage.busy(t))
            return CgateExit.busy
        case .acquire(.off(let m))?:
            ctx.stderr(m)
            return CgateExit.gateOff
        case .acquire(.ticketExpired(let t))?:
            ctx.stderr(CgateMessage.ticketExpired(t))
            return CgateExit.ticketExpired
        default:
            logUngated(ctx, session: session, command: text)
        }

        // Signal handlers before spawn (L3); the forwarder kills once the pid is known.
        let fwd = Forwarder(grace: ctx.killGrace)
        var signalSources: [DispatchSourceSignal] = []
        if ctx.forwardSignals {
            for sig in [SIGINT, SIGTERM, SIGHUP] {
                signal(sig, SIG_IGN)
                let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
                s.setEventHandler { fwd.forward(sig) }
                s.resume()
                signalSources.append(s)
            }
        }
        defer { signalSources.forEach { $0.cancel() } }

        guard let pid = spawn(argv, env: ctx.env) else {
            ctx.stderr("cgate: cannot run \(argv[0])")
            if let job { _ = try? ctx.link.call(.release(ReleaseRequest(jobId: job.id, exitCode: nil, reason: .spawnFailed))) }
            return CgateExit.spawnFailed
        }
        let exited = DispatchSemaphore(value: 0)
        let box = StatusBox()
        Thread.detachNewThread {
            var st: Int32 = 0
            while waitpid(pid, &st, 0) == -1 && errno == EINTR {}
            box.set(st)
            fwd.markExited()
            exited.signal()
        }
        fwd.started(pid)

        var killReason: StopReason?
        var sigkillAt: Date?
        var softNoticed = false
        var nextBeat = Date()  // first heartbeat right away (reports pgid)
        while true {
            var wake = nextBeat
            if let k = sigkillAt { wake = min(wake, k) }
            if exited.wait(timeout: .now() + max(wake.timeIntervalSinceNow, 0)) == .success { break }
            if let k = sigkillAt, Date() >= k {
                kill(-pid, SIGKILL)
                sigkillAt = .distantFuture
            }
            guard Date() >= nextBeat else { continue }
            nextBeat = Date().addingTimeInterval(ctx.heartbeatInterval)
            guard let j = job else { continue }
            switch try? ctx.link.call(.heartbeat(JobHeartbeatRequest(jobId: j.id, pgid: pid))) {
            case .heartbeat(.softStop(let r))?:
                if !softNoticed {
                    softNoticed = true
                    ctx.stderr(r == .walltime ? CgateMessage.walltimeNotice(command: text, max: j.max,
                                                                            grace: walltimeGrace(ctx))
                               : r == .userKill ? CgateMessage.jobStopNotice(command: text)
                               : CgateMessage.softStopNotice)
                }
            case .heartbeat(.hardStop(let r))?:
                if killReason == nil {
                    killReason = r
                    kill(-pid, SIGTERM)
                    sigkillAt = Date().addingTimeInterval(ctx.killGrace)
                }
            case .heartbeat(.unknownJob)?:
                var re = acq
                re.ticket = nil
                re.pgid = pid
                re.maxRuntimeSeconds = j.max
                re.reattach = Reattach(jobId: j.id, startedAt: j.startedAt)
                if case .acquire(.granted(let id, let max))? = try? ctx.link.call(.acquire(re)) {
                    job = (id, max, j.startedAt)
                }
            default:
                break  // continue, or app unreachable: keep running, retry next beat
            }
        }
        let forwarded = fwd.signal
        if killReason != nil || forwarded != nil { kill(-pid, SIGKILL) }  // H1: orphans in the group

        let code = exitCode(box.get())
        let (reason, result): (ReleaseReason, Int32)
        if let killReason {
            reason = .killed
            result = CgateExit.forHardStop(killReason)
            ctx.stderr(killReason == .walltime ? CgateMessage.walltimeKilled(max: job?.max ?? 0)
                                               : CgateMessage.stoppedByUser)
        } else if let forwarded {
            (reason, result) = (.interrupted, 128 + forwarded)
        } else {
            (reason, result) = (.exited, code)
        }
        if let job {
            _ = try? ctx.link.call(.release(ReleaseRequest(jobId: job.id, exitCode: code, reason: reason)))
        }
        return result
    }

    /// `$SHELL` if it is an absolute bash/zsh/sh, else /bin/bash (L1).
    static func shell(_ env: [String: String]) -> String {
        env["SHELL"].flatMap {
            $0.hasPrefix("/") && ["bash", "zsh", "sh"].contains(($0 as NSString).lastPathComponent) ? $0 : nil
        } ?? "/bin/bash"
    }

    /// `wait(2)` status → shell-style exit code (128 + signal when signalled).
    static func exitCode(_ st: Int32) -> Int32 {
        st & 0x7f == 0 ? (st >> 8) & 0xff : 128 + (st & 0x7f)
    }

    /// posix_spawnp in a new process group, default signal dispositions, empty mask.
    static func spawn(_ argv: [String], env: [String: String]) -> pid_t? {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var def = sigset_t()
        sigemptyset(&def)
        for s in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE, SIGCHLD] { sigaddset(&def, s) }
        posix_spawnattr_setsigdefault(&attr, &def)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attr, &mask)

        let cargv = argv.map { strdup($0) } + [nil]
        let cenv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (cargv + cenv).forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawnp(&pid, argv[0], nil, &attr, cargv, cenv)
        return rc == 0 ? pid : nil
    }

    /// GATE-11: one line per ungated run (truncated command, no env).
    static func logUngated(_ ctx: RunContext, session: String, command: String) {
        let dir = (ctx.fallbackLog as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cmd = command.count <= 60 ? command : String(command.prefix(59)) + "…"
        let line = "\(ISO8601DateFormatter().string(from: Date())) ungated session=\(session) "
            + "project=\((ctx.cwd as NSString).lastPathComponent) cmd=\(cmd.replacingOccurrences(of: "\n", with: " "))\n"
        if let h = FileHandle(forWritingAtPath: ctx.fallbackLog) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            h.closeFile()
        } else {
            FileManager.default.createFile(atPath: ctx.fallbackLog, contents: Data(line.utf8))
        }
    }
}

private final class StatusBox: @unchecked Sendable {  // guarded by lock
    private let lock = NSLock()
    private var st: Int32 = 0
    func set(_ v: Int32) { lock.withLock { st = v } }
    func get() -> Int32 { lock.withLock { st } }
}

/// Forwards SIGINT/SIGTERM/SIGHUP to the child's group (also if it arrives before spawn) and
/// escalates to SIGKILL after `grace` if the child is still running.
final class Forwarder: @unchecked Sendable {  // guarded by lock
    private let lock = NSLock()
    private let grace: TimeInterval
    private var pid: pid_t?
    private var sig: Int32?
    private var exited = false

    init(grace: TimeInterval) { self.grace = grace }

    var signal: Int32? { lock.withLock { sig } }

    func forward(_ s: Int32) {
        let p: pid_t? = lock.withLock {
            guard !exited else { return nil }  // only signals that reached a running child count
            if sig == nil { sig = s }
            return pid
        }
        if let p { send(s, to: p) }
    }

    /// Child spawned: deliver a signal that arrived earlier.
    func started(_ p: pid_t) {
        let s: Int32? = lock.withLock { pid = p; return sig }
        if let s { send(s, to: p) }
    }

    func markExited() { lock.withLock { exited = true } }

    private func send(_ s: Int32, to p: pid_t) {
        kill(-p, s)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            if !lock.withLock({ exited }) { kill(-p, SIGKILL) }
        }
    }
}

/// Current walltime grace from the app's settings (older/unreachable app → default).
private func walltimeGrace(_ ctx: RunContext) -> TimeInterval {
    if case .status(let s)? = try? ctx.link.call(.status) { return s.settings.walltimeGraceSeconds }
    return Defaults.walltimeGrace
}
