import Darwin
import Foundation

/// macOS asks for Reminders/Calendar access on behalf of the *responsible* app — normally the client that
/// launched us (Claude, Cursor, a terminal). Those apps often lack the usage descriptions, and then macOS
/// silently refuses without asking. So on start we re-launch ourselves "disclaimed": this binary becomes
/// responsible for itself, and macOS shows its own permission prompt (with the descriptions embedded in it).
enum Responsibility {
    static let marker = "APPLE_REMINDERS_CALENDAR_MCP_DISCLAIMED"

    /// Re-executes the current binary disclaimed and exits with its status. Returns only if that isn't
    /// possible (then we carry on as we are) or if we already are the disclaimed child.
    static func disclaimIfNeeded() {
        guard ProcessInfo.processInfo.environment[marker] == nil,
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return }
        typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        let setDisclaim = unsafeBitCast(symbol, to: SetDisclaim.self)

        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { return }
        defer { posix_spawnattr_destroy(&attr) }
        guard setDisclaim(&attr, 1) == 0 else { return }

        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        var env = ProcessInfo.processInfo.environment
        env[marker] = "1"
        let argv = CommandLine.arguments.map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        // stdin/stdout/stderr are inherited, so the child speaks MCP directly to the client.
        guard posix_spawn(&pid, path, nil, &attr, argv, envp) == 0 else { return }
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig) { s in kill(Responsibility.child, s); exit(0) }
        }
        child = pid
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        exit((status & 0x7f) == 0 ? (status >> 8) & 0xff : 1)
    }

    nonisolated(unsafe) static var child: pid_t = 0
}
