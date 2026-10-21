import Foundation
import Security

/// macOS remembers Reminders/Calendar access by code signature. A local build is signed ad hoc, which is a new
/// identity after every rebuild — so macOS asked again on every test run, however the runner was started
/// (`swift run`, the script, another agent). Before asking for access, the runner re-signs itself and the server
/// it tests with the developer's certificate (stable identity), so one "Allow" lasts across rebuilds.
/// Does nothing when no "Apple Development" / "Developer ID Application" identity (or $CODESIGN_IDENTITY) exists.
enum StableSignature {
    static let selfID = "dev.vekaev.reminders-mcp.e2e"
    static let serverID = "dev.vekaev.reminders-mcp"

    /// Signs the running test binary if it's ad hoc, then re-executes it so the new signature applies.
    static func ensureSelf() {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        guard ensure(path, identifier: selfID) else { return }
        let argv = CommandLine.arguments.map { strdup($0) } + [nil]
        execv(path, argv) // returns only on failure; then carry on unsigned
    }

    /// Returns true when the file at `path` was ad hoc and is now signed with a certificate.
    @discardableResult
    static func ensure(_ path: String, identifier: String) -> Bool {
        guard isAdhoc(path), let identity else { return false }
        // Sign a copy and swap it in: rewriting a binary in place can get a running copy of it killed.
        let tmp = path + ".signing-\(getpid())"
        let fm = FileManager.default
        try? fm.removeItem(atPath: tmp)
        guard (try? fm.copyItem(atPath: path, toPath: tmp)) != nil else { return false }
        guard run("/usr/bin/codesign", ["-f", "-s", identity, "-i", identifier, tmp]) == 0,
              rename(tmp, path) == 0 else { try? fm.removeItem(atPath: tmp); return false }
        return true
    }

    static func isAdhoc(_ path: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return false }
        return (info as? [String: Any])?[kSecCodeInfoCertificates as String] == nil
    }

    static let identity: String? = {
        if let env = ProcessInfo.processInfo.environment["CODESIGN_IDENTITY"], !env.isEmpty { return env }
        let pipe = Pipe()
        guard run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"], output: pipe) == 0 else { return nil }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for kind in ["Developer ID Application", "Apple Development"] {
            if let r = text.range(of: "\"\(kind): [^\"]+\"", options: .regularExpression) {
                return String(text[r].dropFirst().dropLast())
            }
        }
        return nil
    }()

    @discardableResult
    private static func run(_ tool: String, _ args: [String], output: Pipe? = nil) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = output ?? FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
