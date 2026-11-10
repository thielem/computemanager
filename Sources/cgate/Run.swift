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
/// to the fallback log. A single argument after `--` is run via `$SHELL -c` (that is how the
/// hook wraps whole command lines); several arguments are exec'd directly.
enum Runner {
    static func run(_ o: RunOptions, _ ctx: RunContext) -> Int32 {
        let session = o.session ?? SessionLookup.resolve(env: ctx.env)
        let single = o.command.count == 1
        let text = single ? o.command[0] : o.command.map(shellQuote).joined(separator: " ")
        let shell = ctx.env["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/sh"
        let argv = single ? [shell, "-c", o.command[0]] : o.command
        let acq = AcquireRequest(sessionId: session, cwd: ctx.cwd, command: text, pid: getpid(),
                                 maxRuntimeSeconds: o.maxRuntime, ticket: o.ticket,
                                 autoWrapped: o.session != nil,  // only the hook passes --session
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
            exited.signal()
        }
        let interrupted = Flag()
        var signalSources: [DispatchSourceSignal] = []
        if ctx.forwardSignals {
            for sig in [SIGINT, SIGTERM, SIGHUP] {
                signal(sig, SIG_IGN)
                let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
                s.setEventHandler { interrupted.set(); kill(-pid, sig) }
                s.resume()
                signalSources.append(s)
            }
        }

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
                    ctx.stderr(r == .walltime ? CgateMessage.walltimeNotice(command: text, max: j.max)
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
        signalSources.forEach { $0.cancel() }

        let code = exitCode(box.get())
        let (reason, result): (ReleaseReason, Int32)
        if let killReason {
            reason = .killed
            result = CgateExit.forHardStop(killReason)
            ctx.stderr(killReason == .walltime ? CgateMessage.walltimeKilled(max: job?.max ?? 0)
                                               : CgateMessage.stoppedByUser)
        } else if interrupted.isSet {
            (reason, result) = (.interrupted, CgateExit.interrupted)
        } else {
            (reason, result) = (.exited, code)
        }
        if let job {
            _ = try? ctx.link.call(.release(ReleaseRequest(jobId: job.id, exitCode: code, reason: reason)))
        }
        return result
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

final class Flag: @unchecked Sendable {  // guarded by lock
    private let lock = NSLock()
    private var v = false
    func set() { lock.withLock { v = true } }
    var isSet: Bool { lock.withLock { v } }
}
