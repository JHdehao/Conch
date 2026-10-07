#if os(macOS)
import AppKit
#endif
import Foundation
import Speech

/// Conch's interface language, independent of the system's.
///
/// Stored the same way as the per-app language in iOS Settings and macOS System
/// Settings (an app-level `AppleLanguages`), so all three places agree. Bundles
/// pick their localization once at launch, so a change applies on the next launch.
enum AppLanguage {
    private static let key = "AppleLanguages"

    /// Languages Conch ships, e.g. ["zh-Hans", "en", "zh-Hant"].
    static let available = Bundle.main.localizations.filter { $0 != "Base" }

    /// The language the interface is showing now.
    static let current = Bundle.main.preferredLocalizations.first ?? "zh-Hans"

    /// The language chosen for Conch; nil follows the system.
    static var override: String? {
        get {
            guard let id = Bundle.main.bundleIdentifier,
                  let first = (UserDefaults.standard.persistentDomain(forName: id)?[key] as? [String])?.first
            else { return nil }
            return match([first])
        }
        set {
            if let newValue {
                UserDefaults.standard.set([newValue], forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// The system's preferred languages, ignoring Conch's own choice.
    static var systemPreferred: [String] {
        // The global domain; UserDefaults would return Conch's own override.
        CFPreferencesCopyAppValue(key as CFString, kCFPreferencesAnyApplication) as? [String] ?? Locale.preferredLanguages
    }

    /// The language the system settings alone would give Conch.
    static var system: String { match(systemPreferred) }

    private static func match(_ preferences: [String]) -> String {
        Bundle.preferredLocalizations(from: available, forPreferences: preferences).first ?? current
    }

    /// A language's name in its own language, as language lists usually show it.
    static func nativeName(_ code: String) -> String {
        switch code {
        case "zh-Hans": "简体中文"
        case "zh-Hant": "繁體中文"
        default: Locale(identifier: code).localizedString(forIdentifier: code)?.capitalizedFirst ?? code
        }
    }

    /// A language's name in the interface language.
    static func localizedName(_ code: String) -> String {
        switch code {
        case "zh-Hans": String(localized: "简体中文")
        case "zh-Hant": String(localized: "繁体中文")
        default: Locale(identifier: current).localizedString(forIdentifier: code)?.capitalizedFirst ?? code
        }
    }

    #if os(macOS)
    /// Opens a fresh copy of Conch, then quits this one.
    @MainActor
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    #endif
}

/// The language dictation listens for. Follows the interface language unless the
/// user picks one, so an English iPhone can still run Conch and dictation in Chinese.
enum SpeechLanguage {
    /// Recognizer locale identifier such as "zh-CN"; empty follows the interface.
    static let key = "speech.language"

    /// Every language the speech recognizer handles, e.g. "zh-CN", "en-US".
    static let supported: [String] = SFSpeechRecognizer.supportedLocales()
        .map(\.identifier)
        .filter { !$0.contains("translit") }

    static var setting: String {
        get { UserDefaults.standard.string(forKey: key) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The recognizer language that matches the interface, if there is one.
    static var followingInterface: String? { bestMatch(for: AppLanguage.current) }

    /// The locale to recognize right now.
    static var locale: Locale {
        let id = setting.isEmpty ? followingInterface : setting
        return Locale(identifier: id ?? AppLanguage.current)
    }

    private static let recentKey = "speech.recent"

    /// Notes a language the user picked, so it stays in the quick menu afterwards.
    static func remember(_ id: String) {
        guard !id.isEmpty else { return }
        let recent = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        UserDefaults.standard.set(Array(([id] + recent.filter { $0 != id }).prefix(4)), forKey: recentKey)
    }

    /// Languages this user most likely speaks: the interface's and the system's,
    /// each mapped to a recognizer language, then the ones picked recently.
    static var suggested: [String] {
        var result: [String] = []
        for id in [AppLanguage.current] + AppLanguage.systemPreferred {
            if let match = bestMatch(for: id), !result.contains(match) { result.append(match) }
        }
        let recent = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        for id in [setting] + recent where !id.isEmpty && supported.contains(id) && !result.contains(id) {
            result.append(id)
        }
        return result
    }

    /// All recognizer languages, sorted by their name in the interface language.
    static var all: [String] {
        supported.sorted { displayName($0).localizedStandardCompare(displayName($1)) == .orderedAscending }
    }

    /// Maps a language such as "zh-Hans" or "en-GB" to the closest recognizer
    /// language: same language and script, then the closest region.
    static func bestMatch(for identifier: String) -> String? {
        let asked = Locale.Language(identifier: identifier)
        let wanted = maximal(identifier)
        // The language's home region regardless of where the user is: an English
        // iPhone set to China reports "en-CN", which should become en-US.
        let home = maximal([wanted.languageCode?.identifier, wanted.script?.identifier].compactMap { $0 }.joined(separator: "-")).region
        let candidates = supported.filter {
            let language = maximal($0)
            return language.languageCode == wanted.languageCode && language.script == wanted.script
        }.sorted()
        for region in [asked.region, Locale.current.region, home].compactMap({ $0 }) {
            if let hit = candidates.first(where: { maximal($0).region == region }) { return hit }
        }
        return candidates.first
    }

    private static func maximal(_ identifier: String) -> Locale.Language {
        Locale.Language(identifier: Locale.Language(identifier: identifier).maximalIdentifier)
    }

    /// e.g. "普通话（中国大陆）", "英语（美国）".
    static func displayName(_ identifier: String) -> String {
        // Chinese recognizers differ by spoken language, which the generic
        // "中文（香港）" style names hide.
        switch identifier {
        case "zh-CN": String(localized: "普通话（中国大陆）")
        case "zh-TW": String(localized: "普通话（台湾）")
        case "zh-HK": String(localized: "粤语（香港）")
        case "yue-CN": String(localized: "粤语（中国大陆）")
        case "wuu-CN": String(localized: "吴语（中国大陆）")
        default: Locale(identifier: AppLanguage.current).localizedString(forIdentifier: identifier)?.capitalizedFirst ?? identifier
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
