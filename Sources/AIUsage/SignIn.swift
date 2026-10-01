import AppKit

struct SignInAttempt {
    let marker: URL
    let credentialFile: URL
    let initialModification: Date?
    let started: Date
    func hasCompleted() -> Bool {
        if FileManager.default.fileExists(atPath: marker.path) { return true }
        let modified = try? credentialFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return modified != nil && modified != initialModification && modified! >= started.addingTimeInterval(-1)
    }
}

enum SignInLauncher {
    @MainActor static func open(_ provider: Provider) throws -> SignInAttempt? {
        guard let executable = ProviderClient.executable(provider == .codex ? "codex" : "claude") else {
            NSWorkspace.shared.open(URL(string: provider == .codex ? "https://developers.openai.com/codex/cli" : "https://code.claude.com/docs/en/setup")!)
            return nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = home.appendingPathComponent("Library/Application Support/AIUsage")
        let marker = folder.appendingPathComponent("login-\(UUID().uuidString).complete")
        let file = folder.appendingPathComponent("Sign in to \(provider.rawValue).command")
        let credential = home.appendingPathComponent(provider == .claude ? ".claude/.credentials.json" : ".codex/auth.json")
        let attempt = SignInAttempt(marker: marker, credentialFile: credential, initialModification: try? credential.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, started: Date())
        let command = provider == .codex ? "login" : "auth login --claudeai"
        let script = "#!/bin/zsh\nexport PATH=\(quote(executable.deletingLastPathComponent().path)):/usr/bin:/bin:/usr/sbin:/sbin\nif \(quote(executable.path)) \(command); then\n  /usr/bin/touch \(quote(marker.path))\n  printf '\\nConnected. AI Usage will refresh automatically.\\n'\nfi\n"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        guard NSWorkspace.shared.open(file) else { throw UsageFailure.unavailable }
        return attempt
    }

    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
