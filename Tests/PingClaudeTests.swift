import Foundation

@main
struct PingClaudeTests {
    static func main() {
        testPingService()
        print("🎉 All tests passed!")
    }

    static func testPingService() {
        print("--- Testing PingService ---")
        
        let settingsStore = SettingsStore()
        let sut = PingService(settingsStore: settingsStore)

        print("Test: extractSessionKey...")
        let setCookie = "sessionKey=sk-ant-12345; Domain=api.claude.ai; Path=/; HttpOnly; Secure; SameSite=Lax"
        let key = sut.extractSessionKey(from: setCookie)
        assert_eq(key, "sk-ant-12345", "Failed to extract session key")

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
