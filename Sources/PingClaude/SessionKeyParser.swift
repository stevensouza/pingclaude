import Foundation

/// Parsing and validation for the claude.ai `sessionKey` cookie.
///
/// The server may send a cookie-clearing `Set-Cookie` header (`sessionKey=""; Expires=<past>`)
/// on an otherwise successful response. Accepting such a value overwrites a working credential
/// with garbage and locks the app out until the user re-enters the key by hand, so every value
/// coming off the wire must pass `isValid` before it is persisted.
/// URLSession for claude.ai calls, with cookie handling disabled.
///
/// `URLSession.shared` keeps its own cookie jar and merges it into a manually-set `Cookie`
/// header, so a server-sent logout cookie can linger there and break auth even after the stored
/// session key is corrected. Every request here sets `Cookie` explicitly, so the jar is only a
/// source of surprise.
enum ClaudeAPISession {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()
}

enum SessionKeyParser {

    /// Prefix every real claude.ai session key carries.
    static let keyPrefix = "sk-ant-"

    /// Shortest value we will treat as a credential rather than a placeholder.
    static let minimumKeyLength = 20

    /// Whether a value looks like a usable session key.
    static func isValid(_ key: String) -> Bool {
        key.hasPrefix(keyPrefix) && key.count >= minimumKeyLength
    }

    /// Normalize a value for storage: trim whitespace, unwrap surrounding quotes, and drop an
    /// accidentally-pasted `sessionKey=` prefix.
    static func sanitize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = unquote(value)
        if value.hasPrefix(cookieName + "=") {
            value = String(value.dropFirst(cookieName.count + 1))
        }
        return unquote(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Extract a refreshed session key from a `Set-Cookie` response header.
    ///
    /// Returns `nil` — meaning "keep the key we already have" — when the header carries no
    /// `sessionKey` cookie, clears it, or holds a value that does not look like a credential.
    static func extract(from setCookieHeader: String, url: URL? = nil) -> String? {
        guard let (value, attributes) = rawCookie(from: setCookieHeader, url: url) else { return nil }
        guard !isDeletion(attributes) else { return nil }

        let key = sanitize(value)
        return isValid(key) ? key : nil
    }

    // MARK: - Cookie extraction

    private static let cookieName = "sessionKey"

    /// The `sessionKey` value plus the attributes of that same cookie, or `nil` if absent.
    ///
    /// `HTTPURLResponse.value(forHTTPHeaderField:)` folds repeated `Set-Cookie` headers together
    /// with ", ", and `Expires` dates contain a comma of their own, so a naive split cannot tell
    /// the two apart. `HTTPCookie` understands that folding; the manual scan is a fallback for
    /// headers it declines to parse.
    private static func rawCookie(from header: String, url: URL?) -> (value: String, attributes: [String])? {
        if let cookieURL = url ?? URL(string: "https://claude.ai") {
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: cookieURL)
            if let cookie = cookies.first(where: { $0.name == cookieName }) {
                // HTTPCookie resolves Expires/Max-Age into expiresDate for us.
                var attributes: [String] = []
                if let expiry = cookie.expiresDate, expiry <= Date() {
                    attributes.append("Max-Age=0")
                }
                return (cookie.value, attributes)
            }
            if !cookies.isEmpty {
                // Header parsed cleanly and simply carried no sessionKey cookie.
                return nil
            }
        }
        return manualScan(header)
    }

    /// Fallback `;`-delimited scan for headers `HTTPCookie` could not parse.
    private static func manualScan(_ header: String) -> (value: String, attributes: [String])? {
        let parts = header.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let index = parts.firstIndex(where: { $0.hasPrefix(cookieName + "=") }) else { return nil }
        let value = String(parts[index].dropFirst(cookieName.count + 1))
        // Attributes trail the cookie they belong to.
        return (value, Array(parts.dropFirst(index + 1)))
    }

    /// Whether the attributes mark the cookie for deletion.
    private static func isDeletion(_ attributes: [String]) -> Bool {
        for attribute in attributes {
            let lowered = attribute.lowercased()
            if lowered.hasPrefix("max-age=") {
                let raw = String(attribute.dropFirst("max-age=".count)).trimmingCharacters(in: .whitespaces)
                if let seconds = Int(raw), seconds <= 0 { return true }
            }
            if lowered.hasPrefix("expires="),
               let expiry = expiryDate(from: String(attribute.dropFirst("expires=".count))),
               expiry <= Date() {
                return true
            }
        }
        return false
    }

    private static let expiryFormatters: [DateFormatter] = ["EEE, dd MMM yyyy HH:mm:ss zzz",
                                                            "EEE, dd-MMM-yyyy HH:mm:ss zzz"].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = format
        return formatter
    }

    private static func expiryDate(from raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        for formatter in expiryFormatters {
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }
}
