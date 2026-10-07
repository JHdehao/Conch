import Foundation

/// Trust-on-first-use host key store, keyed by "host:port".
enum KnownHosts {
    private static let defaultsKey = "knownHosts"

    enum Verdict {
        case trusted
        case unknown
        case mismatch(expected: String)
    }

    static func key(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    static var all: [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    static func check(host: String, port: Int, fingerprint: String) -> Verdict {
        guard let stored = all[key(host: host, port: port)] else { return .unknown }
        return stored == fingerprint ? .trusted : .mismatch(expected: stored)
    }

    static func trust(host: String, port: Int, fingerprint: String) {
        var hosts = all
        hosts[key(host: host, port: port)] = fingerprint
        UserDefaults.standard.set(hosts, forKey: defaultsKey)
    }

    static func forget(_ key: String) {
        var hosts = all
        hosts.removeValue(forKey: key)
        UserDefaults.standard.set(hosts, forKey: defaultsKey)
    }
}
