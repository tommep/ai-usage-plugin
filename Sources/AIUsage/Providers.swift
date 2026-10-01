import Foundation

enum ProviderClient {
    static func stop() { ChildProcess.stopAll() }
    static func fetch(_ provider: Provider) async throws -> UsageSnapshot {
        switch provider {
        case .codex: return try await Task.detached(priority: .utility) { try codex() }.value
        case .claude: return try await claude()
        }
    }

    static func executable(_ name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = [home.appendingPathComponent(".local/bin/\(name)"), home.appendingPathComponent(".claude/local/\(name)"), URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"), URL(fileURLWithPath: "/usr/local/bin/\(name)")]
        let versions = home.appendingPathComponent(".nvm/versions/node")
        if let children = try? FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil) {
            paths += children.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }.map { $0.appendingPathComponent("bin/\(name)") }
        }
        paths += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: "\($0)/\(name)") }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func codex() throws -> UsageSnapshot {
        guard let binary = executable("codex") else { throw UsageFailure.missingCLI }
        let started = Date()
        let child = try ChildProcess(binary, ["app-server", "--stdio"])
        defer { child.close() }
        try child.send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "ai_usage", "version": "0.1.0"]]])
        while let line = try child.line() {
            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if value["id"] as? Int == 1 {
                guard value["error"] == nil else { throw UsageFailure.unavailable }
                try child.send(["method": "initialized"])
                try child.send(["id": 2, "method": "account/rateLimits/read"])
            } else if value["id"] as? Int == 2 {
                if value["error"] != nil { throw UsageFailure.signIn }
                return try UsageParser.codex(line, at: started)
            }
        }
        throw child.timedOut ? UsageFailure.timeout : UsageFailure.unavailable
    }

    private static func claude() async throws -> UsageSnapshot {
        let started = Date()
        let token = try await Task.detached(priority: .utility) { try claudeToken() }.value
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 20
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw UsageFailure.unavailable }
            switch response.statusCode {
            case 200:
                guard data.count <= 1_000_000 else { throw UsageFailure.invalidData }
                return try UsageParser.claude(data, at: started)
            case 401, 403: throw UsageFailure.signIn
            case 429: throw UsageFailure.throttled
            default: throw UsageFailure.unavailable
            }
        } catch let error as URLError {
            throw error.code == .timedOut ? UsageFailure.timeout : UsageFailure.unavailable
        }
    }

    // Credentials stay in memory and are sent only to the provider's usage endpoint.
    private static func claudeToken() throws -> String {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_000_000,
           let data = try? Data(contentsOf: file), let token = validToken(data) { return token }
        let child = try ChildProcess(URL(fileURLWithPath: "/usr/bin/security"), ["find-generic-password", "-s", "Claude Code-credentials", "-w"], timeout: 10)
        defer { child.close() }
        let data = try child.all()
        guard let token = validToken(data) else { throw UsageFailure.signIn }
        return token
    }

    private static func validToken(_ data: Data) -> String? {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = value["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        if let expires = oauth["expiresAt"] as? Double, expires / 1000 <= Date().timeIntervalSince1970 + 30 { return nil }
        return token
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class ChildProcess {
    private static let registryLock = NSLock()
    private static var running: [UUID: Process] = [:]
    private let id = UUID()
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var timer: DispatchSourceTimer?
    private var buffer = Data()
    private var bytesRead = 0
    private let lock = NSLock()
    private var timeoutFlag = false
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return timeoutFlag }

    init(_ executable: URL, _ arguments: [String], timeout: Double = 20) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = executable.deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env
        // Do not load workspace instructions or run any model turns.
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        try process.run()
        Self.registryLock.lock(); Self.running[id] = process; Self.registryLock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.timeoutFlag = true; self.lock.unlock()
            if self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) }
        }
        self.timer = timer
        timer.resume()
    }

    func send(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func line() throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                return Data(line)
            }
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { return nil }
            bytesRead += chunk.count
            guard bytesRead <= 1_000_000 else { throw UsageFailure.invalidData }
            buffer.append(chunk)
        }
    }

    func all() throws -> Data {
        var data = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= 1_000_000 else { throw UsageFailure.invalidData }
        }
        if timedOut { throw UsageFailure.timeout }
        return data
    }

    func close() {
        timer?.cancel()
        try? input.fileHandleForWriting.close()
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
        Self.registryLock.lock(); Self.running.removeValue(forKey: id); Self.registryLock.unlock()
    }

    static func stopAll() {
        registryLock.lock(); let children = Array(running.values); registryLock.unlock()
        for process in children where process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}
