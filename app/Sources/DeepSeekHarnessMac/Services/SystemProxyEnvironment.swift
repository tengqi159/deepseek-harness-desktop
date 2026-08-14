import Foundation
import SystemConfiguration

enum SystemProxyEnvironment {
    static func values() -> [String: String] {
        guard let raw = SCDynamicStoreCopyProxies(nil) as? [String: Any] else {
            return [:]
        }

        let httpsProxy = proxyURL(
            raw,
            enabledKey: kSCPropNetProxiesHTTPSEnable as String,
            hostKey: kSCPropNetProxiesHTTPSProxy as String,
            portKey: kSCPropNetProxiesHTTPSPort as String
        )

        let httpProxy = proxyURL(
            raw,
            enabledKey: kSCPropNetProxiesHTTPEnable as String,
            hostKey: kSCPropNetProxiesHTTPProxy as String,
            portKey: kSCPropNetProxiesHTTPPort as String
        )

        guard let preferred = httpsProxy ?? httpProxy else {
            return [:]
        }

        return [
            "NODE_USE_ENV_PROXY": "1",
            "HTTP_PROXY": httpProxy ?? preferred,
            "HTTPS_PROXY": httpsProxy ?? preferred,
            "NO_PROXY": "127.0.0.1,localhost,::1"
        ]
    }

    private static func proxyURL(
        _ values: [String: Any],
        enabledKey: String,
        hostKey: String,
        portKey: String
    ) -> String? {
        guard number(values[enabledKey]) == 1,
              let host = values[hostKey] as? String,
              !host.isEmpty,
              let port = number(values[portKey]),
              port > 0 else {
            return nil
        }

        return "http://\(host):\(port)"
    }

    private static func number(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? Int { return value }
        if let value = value as? String { return Int(value) }
        return nil
    }
}
