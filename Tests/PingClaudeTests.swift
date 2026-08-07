import Foundation

@main
struct PingClaudeTests {
    static func main() {
        testSessionKeyParser()
        testPingService()
        print("🎉 All tests passed!")
    }

    /// A structurally valid key, long enough to clear the minimum-length check.
    static let goodKey = "sk-ant-sid01-" + String(repeating: "A", count: 40)

    static func testSessionKeyParser() {
        print("--- Testing SessionKeyParser ---")

        print("Test: extract from a normal refresh...")
        assert_eq(
            SessionKeyParser.extract(from: "sessionKey=\(goodKey); Domain=.claude.ai; Path=/; HttpOnly; Secure; SameSite=Lax"),
            goodKey,
            "Failed to extract a valid session key"
        )

        // The 2026-08-07 outage: a 200 response carrying a logout cookie overwrote a working key.
        print("Test: cookie-clearing header is rejected...")
        assert_eq(
            SessionKeyParser.extract(from: "sessionKey=\"\"; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/"),
            nil,
            "Quoted-empty logout cookie must not be accepted"
        )

        print("Test: empty value is rejected...")
        assert_eq(SessionKeyParser.extract(from: "sessionKey=; Path=/"), nil, "Empty value must be rejected")

        print("Test: Max-Age=0 deletion is rejected...")
        assert_eq(
            SessionKeyParser.extract(from: "sessionKey=\(goodKey); Path=/; Max-Age=0"),
            nil,
            "Max-Age=0 marks deletion and must be rejected"
        )

        print("Test: quoted valid value is unwrapped...")
        assert_eq(
            SessionKeyParser.extract(from: "sessionKey=\"\(goodKey)\"; Path=/"),
            goodKey,
            "Surrounding quotes should be stripped"
        )

        print("Test: header without sessionKey...")
        assert_eq(SessionKeyParser.extract(from: "lastActiveOrg=00000000; Path=/"), nil, "No sessionKey cookie")

        print("Test: non-credential values are rejected...")
        assert_eq(SessionKeyParser.extract(from: "sessionKey=deleted; Path=/"), nil, "Wrong prefix")
        assert_eq(SessionKeyParser.extract(from: "sessionKey=sk-ant-1; Path=/"), nil, "Too short")

        print("Test: folded multi-cookie header...")
        let folded = "intercom-session=abc; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/, sessionKey=\(goodKey); Path=/; Secure"
        assert_eq(SessionKeyParser.extract(from: folded), goodKey, "Comma inside Expires must not corrupt parsing")

        print("Test: sanitize...")
        assert_eq(SessionKeyParser.sanitize("  \(goodKey)\n "), goodKey, "Whitespace should be trimmed")
        assert_eq(SessionKeyParser.sanitize("\"\(goodKey)\""), goodKey, "Quotes should be stripped")
        assert_eq(SessionKeyParser.sanitize("sessionKey=\(goodKey)"), goodKey, "Pasted cookie prefix should be stripped")
        assert_eq(SessionKeyParser.sanitize("\"\""), "", "Quoted-empty should sanitize to empty")

        print("Test: isValid...")
        assert_eq(SessionKeyParser.isValid(goodKey), true, "Good key should validate")
        assert_eq(SessionKeyParser.isValid(""), false, "Empty should not validate")
        assert_eq(SessionKeyParser.isValid("\"\""), false, "Literal quotes should not validate")

        print("✅ SessionKeyParser tests passed!")
    }

    static func testPingService() {
        print("--- Testing PingService ---")
        
        let settingsStore = SettingsStore()
        let sut = PingService(settingsStore: settingsStore)

        print("Test: extractDeltaText...")
        let json = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#
        let text = sut.extractDeltaText(from: json)
        assert_eq(text, "Hello", "Failed to extract delta text")

        print("Test: parseMessageLimit...")
        let limitJson = """
        {
          "type": "message_limit",
          "message_limit": {
            "windows": {
              "5h": { "utilization": 0.44, "resets_at": 1707328800 }
            }
          }
        }
        """
        let usage = sut.parseMessageLimit(from: limitJson)
        assert_eq(usage?.sessionUtilization, 0.44, "Failed to parse session utilization")
        assert_eq(usage?.sessionResetsAt, 1707328800.0, "Failed to parse session reset time")

        print("✅ PingService tests passed!")
    }

    static func assert_eq<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: String = #file, line: Int = #line) {
        if actual != expected {
            print("❌ Assertion Failed: \(message)")
            print("   Actual: \(actual)")
            print("   Expected: \(expected)")
            print("   at \(file):\(line)")
            exit(1)
        }
    }
}
