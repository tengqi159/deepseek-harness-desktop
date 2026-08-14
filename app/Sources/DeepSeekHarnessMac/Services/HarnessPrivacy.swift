import Foundation

enum HarnessPrivacy {
    private static let secretPatterns: [NSRegularExpression] = [
        #"(?i)\bsk-[a-z0-9_-]{12,}\b"#,
        #"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#,
        #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#,
        #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{12,}"#,
        #"(?i)\b(?:api[_ -]?key|access[_ -]?token|secret|password|passcode)\s*[:=]\s*[^\s,;]{8,}"#,
        #"-----BEGIN [^-\r\n]{0,50}PRIVATE KEY-----[\s\S]*"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func redact(_ text: String, limit: Int = 40_000) -> String {
        var value = text
        for pattern in secretPatterns {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            value = pattern.stringByReplacingMatches(
                in: value,
                range: range,
                withTemplate: "<redacted secret>"
            )
        }
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "\n…内容已截断…"
    }

    static func isSensitiveBundle(_ bundleIdentifier: String?) -> Bool {
        guard let identifier = bundleIdentifier?.lowercased(), !identifier.isEmpty else {
            return true
        }
        return [
            "com.apple.passwords",
            "com.apple.keychainaccess",
            "com.apple.securityagent",
            "com.apple.loginwindow",
            "com.1password.1password",
            "com.agilebits.onepassword7",
            "com.bitwarden.desktop",
            "com.dashlane.dashlane",
            "com.lastpass.lastpass"
        ].contains(identifier)
    }

    static func isSensitiveElement(role: String?, subrole: String?, label: String?) -> Bool {
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            return true
        }
        let lowered = (label ?? "").lowercased()
        return [
            "password", "passcode", "secret", "token", "api key", "apikey",
            "recovery code", "private key", "credit card", "cvv", "one-time",
            "otp", "verification code", "密码", "口令", "密钥", "恢复码", "验证码", "银行卡"
        ].contains { lowered.contains($0) }
    }
}
