import Foundation

struct ClaudeCredential {
    let accessToken: String
    let expiresAt: Date?
    let canRenew: Bool

    init?(_ data: Data) {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = value["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        accessToken = token
        expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        canRenew = !(oauth["refreshToken"] as? String ?? "").isEmpty
    }

    func usable(at date: Date = Date(), margin: Double = 30) -> Bool {
        expiresAt.map { $0.timeIntervalSince(date) > margin } ?? true
    }
}

enum ClaudeLogin {
    // The official CLI owns refresh-token rotation, locking and credential writes.
    // AI Usage never submits a prompt or writes the shared credentials itself.
    static func token(read: () throws -> ClaudeCredential = read,
                      renew: (ClaudeCredential) throws -> String = { try renew($0) }) throws -> String {
        let credential = try read()
        if credential.usable(margin: 300) { return credential.accessToken }
        guard credential.canRenew else {
            if credential.usable() { return credential.accessToken }
            throw UsageFailure.signIn
        }
        do { return try renew(credential) }
        catch {
            // A failed proactive renewal must not discard a still-usable token.
            if credential.usable() { return credential.accessToken }
            throw error
        }
    }

    static func recover(rejectedToken: String,
                        read: () throws -> ClaudeCredential = read,
                        renew: (ClaudeCredential) throws -> String = { try renew($0) }) throws -> String {
        let credential = try read()
        // Claude may already have rotated the login in another session.
        if credential.accessToken != rejectedToken, credential.usable() { return credential.accessToken }
        guard credential.canRenew else { throw UsageFailure.signIn }
        let token = try renew(credential)
        guard token != rejectedToken else { throw UsageFailure.signIn }
        return token
    }

    static func read() throws -> ClaudeCredential {
        // On macOS the CLI stores renewals in Keychain. A leftover file can be older.
        let child = try ChildProcess(URL(fileURLWithPath: "/usr/bin/security"),
                                     ["find-generic-password", "-s", "Claude Code-credentials", "-w"], timeout: 10)
        defer { child.close() }
        if let data = try? child.all(), let credential = ClaudeCredential(data) { return credential }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_000_000,
           let data = try? Data(contentsOf: file), let credential = ClaudeCredential(data) { return credential }
        throw UsageFailure.signIn
    }

    static let arguments = ["--print", "--input-format", "stream-json", "--output-format", "stream-json",
                            "--verbose", "--safe-mode", "--no-session-persistence", "--tools", "",
                            "--setting-sources", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}"]

    static func renew(_ credential: ClaudeCredential,
                      read: () throws -> ClaudeCredential = read,
                      executable suppliedExecutable: URL? = nil, timeout: Double = 40) throws -> String {
        guard let executable = suppliedExecutable ?? ProviderClient.executable("claude") else { throw UsageFailure.missingCLI }
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("ANTHROPIC_") || key.hasPrefix("CLAUDE_CODE_") || key == "CLAUDE_CONFIG_DIR" {
            environment.removeValue(forKey: key)
        }
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ai-usage-renew-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let child = try ChildProcess(executable, arguments, timeout: timeout + 10, environment: environment, directory: directory)
        defer { child.close() }
        // Only an SDK control message; no user message or inference request.
        try child.send(["type": "control_request", "request_id": "usage-login",
                        "request": ["subtype": "initialize"]])
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, child.isRunning {
            Thread.sleep(forTimeInterval: 1)
            let current = try read()
            if !current.canRenew, !current.usable() { throw UsageFailure.signIn }
            if current.accessToken != credential.accessToken, current.usable() { return current.accessToken }
        }
        // Startup only refreshes expiring tokens. A still-valid rejected token
        // that remains unchanged is a real reconnect case, not an endless retry.
        if credential.usable() { return credential.accessToken }
        throw UsageFailure.timeout
    }
}
