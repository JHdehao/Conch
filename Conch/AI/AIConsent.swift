import Foundation

/// Whether the user agreed to send chat data to an AI service. Asked once per
/// service, before anything leaves the device (App Store guideline 5.1.2(i)).
enum AIConsent {
    /// v2: the card also names the web lookup services, so earlier agreements are asked again once.
    private static let key = "ai.consentedServices.v2"

    /// Provider and host (a new address is a different third party), plus whether
    /// fast web lookup is on, since that sends searches to further services.
    static func id(_ config: AIConfiguration) -> String {
        "\(config.provider.rawValue)|\(config.serviceHost)" + (WebLookup.isEnabled ? "|web" : "")
    }

    static func isGranted(_ config: AIConfiguration) -> Bool {
        granted.contains(id(config))
    }

    static func grant(_ config: AIConfiguration) {
        guard !isGranted(config) else { return }
        UserDefaults.standard.set(granted + [id(config)], forKey: key)
    }

    static func revoke(_ config: AIConfiguration) {
        UserDefaults.standard.set(granted.filter { $0 != id(config) }, forKey: key)
    }

    private static var granted: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }
}

/// Shown instead of sending until the user agrees.
struct ConsentRequest: Equatable {
    let service: String
    let host: String
    /// The message that's waiting; sent on agreement, handed back on refusal.
    let message: String
    var attachments: [Attachment] = []
}
