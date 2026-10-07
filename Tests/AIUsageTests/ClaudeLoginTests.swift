import XCTest
@testable import AIUsage

final class ClaudeLoginTests: XCTestCase {
    private func credential(_ token: String = "old", seconds: Double = -60, refresh: String = "renew") -> ClaudeCredential {
        let data = try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": [
            "accessToken": token, "expiresAt": Date().addingTimeInterval(seconds).timeIntervalSince1970 * 1000,
            "refreshToken": refresh]])
        return ClaudeCredential(data)!
    }

    func testFreshLoginDoesNotStartCLI() throws {
        XCTAssertEqual(try ClaudeLogin.token(read: { self.credential(seconds: 3600) }, renew: { _ in
            XCTFail("Fresh login must not renew"); return "unexpected"
        }), "old")
    }

    func testExpiredAndNearlyExpiredLoginRenewBeforeReadingUsage() throws {
        for seconds in [-60.0, 120.0] {
            var attempts = 0
            let token = try ClaudeLogin.token(read: { self.credential(seconds: seconds) }, renew: { _ in
                attempts += 1; return "new"
            })
            XCTAssertEqual(token, "new")
            XCTAssertEqual(attempts, 1)
        }
    }

    func testProactiveFailureKeepsUsableTokenButExpiredFailureRemainsStale() throws {
        XCTAssertEqual(try ClaudeLogin.token(read: { self.credential(seconds: 120) }, renew: { _ in throw UsageFailure.timeout }), "old")
        XCTAssertThrowsError(try ClaudeLogin.token(read: { self.credential() }, renew: { _ in throw UsageFailure.timeout })) {
            XCTAssertEqual($0 as? UsageFailure, .timeout)
        }
    }

    func testUnrenewableExpiredLoginRequiresSignIn() {
        XCTAssertThrowsError(try ClaudeLogin.token(read: { self.credential(refresh: "") }, renew: { _ in
            XCTFail("Missing refresh token must not start CLI"); return "new"
        })) { XCTAssertEqual($0 as? UsageFailure, .signIn) }
    }

    func testRejectionUsesConcurrentRotationOrOneRenewal() throws {
        XCTAssertEqual(try ClaudeLogin.recover(rejectedToken: "old", read: { self.credential("new", seconds: 3600) }, renew: { _ in
            XCTFail("Another session already renewed"); return "unexpected"
        }), "new")
        var attempts = 0
        XCTAssertThrowsError(try ClaudeLogin.recover(rejectedToken: "old", read: { self.credential(seconds: 3600) }, renew: { _ in
            attempts += 1; return "old"
        })) { XCTAssertEqual($0 as? UsageFailure, .signIn) }
        XCTAssertEqual(attempts, 1)
    }

    func testRenewalProcessOnlyReceivesControlMessageAndWaitsForSavedToken() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("claude")
        let marker = folder.appendingPathComponent("saved")
        // A fake official CLI saves new credentials only after receiving initialize.
        let script = "#!/usr/bin/python3\nimport sys,json,time\nx=json.loads(sys.stdin.readline())\nassert x['type']=='control_request' and x['request']['subtype']=='initialize'\nassert '--safe-mode' in sys.argv and '--no-session-persistence' in sys.argv\nopen(\(String(reflecting: marker.path)), 'w').write('saved')\ntime.sleep(10)\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let token = try ClaudeLogin.renew(credential(), read: {
            FileManager.default.fileExists(atPath: marker.path) ? self.credential("new", seconds: 3600) : self.credential()
        }, executable: executable, timeout: 3)
        XCTAssertEqual(token, "new")
    }

    func testRenewalTimeoutIsBoundedWithoutInventingLoginSuccess() throws {
        let start = Date()
        XCTAssertThrowsError(try ClaudeLogin.renew(credential(), read: { self.credential() }, executable: URL(fileURLWithPath: "/usr/bin/yes"), timeout: 0.1)) {
            XCTAssertEqual($0 as? UsageFailure, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}
