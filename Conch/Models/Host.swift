import Foundation
import SwiftData
import SwiftUI

enum AuthMethod: String, Codable, CaseIterable, Identifiable {
    case password
    case key

    var id: String { rawValue }

    var label: String {
        switch self {
        case .password: String(localized: "密码")
        case .key: String(localized: "密钥")
        }
    }
}

enum ConnectionProtocol: String, Codable, CaseIterable, Identifiable {
    case ssh
    case mosh

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ssh: "SSH"
        case .mosh: "Mosh"
        }
    }
}

/// Tag colors: the muted hues of the Claude terminal themes (so a server's color
/// matches the palette its terminal is drawn in), a shade lighter in dark mode.
enum HostTint: String, Codable, CaseIterable, Identifiable {
    case blue, green, orange, red, purple, pink, teal, gray

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue: Color(light: 0x5A87B5, dark: 0x7FA8D4)
        case .green: Color(light: 0x6F8452, dark: 0x9DB37E)
        case .orange: Color(light: 0xD97757, dark: 0xE08A6C)
        case .red: Color(light: 0xB8513E, dark: 0xE0685A)
        case .purple: Color(light: 0x8C6BA8, dark: 0xB195CC)
        case .pink: Color(light: 0xA8699A, dark: 0xC58FB5)
        case .teal: Color(light: 0x4F8C85, dark: 0x7FB8B0)
        case .gray: Color(light: 0x87867F, dark: 0xA8A69E)
        }
    }
}

@Model
final class Host {
    var id: UUID = UUID()
    var name: String = ""
    var hostname: String = ""
    var port: Int = 22
    var username: String = ""
    var group: String = ""
    var authMethodRaw: String = AuthMethod.password.rawValue
    var protocolRaw: String = ConnectionProtocol.ssh.rawValue
    var tintRaw: String = HostTint.blue.rawValue
    var keyID: UUID?
    /// Remote command used to start mosh-server; empty means the default.
    var moshServerCommand: String = ""
    /// tmux session to enter after connecting (and re-enter after reconnecting); empty means off.
    var tmuxSession: String = ""
    var createdAt: Date = Date()
    var lastConnectedAt: Date?
    /// Last time the settings were edited; decides which copy wins when devices share.
    /// Optional so existing stores migrate without a default.
    var updatedAt: Date?

    init(name: String = "", hostname: String = "", port: Int = 22, username: String = "") {
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
    }

    var authMethod: AuthMethod {
        get { AuthMethod(rawValue: authMethodRaw) ?? .password }
        set { authMethodRaw = newValue.rawValue }
    }

    var connectionProtocol: ConnectionProtocol {
        get { ConnectionProtocol(rawValue: protocolRaw) ?? .ssh }
        set { protocolRaw = newValue.rawValue }
    }

    var tint: HostTint {
        get { HostTint(rawValue: tintRaw) ?? .blue }
        set { tintRaw = newValue.rawValue }
    }

    var displayName: String {
        name.isEmpty ? hostname : name
    }

    var subtitle: String {
        let target = username.isEmpty ? hostname : "\(username)@\(hostname)"
        return port == 22 ? target : "\(target):\(port)"
    }

    /// Keychain account under which this host's password is stored.
    var passwordAccount: String { "host-password-\(id.uuidString)" }

    /// When the settings last changed, for picking the newer copy while sharing.
    var modifiedAt: Date { updatedAt ?? createdAt }
}

@Model
final class SSHKey {
    var id: UUID = UUID()
    var name: String = ""
    var keyType: String = ""
    var publicKey: String = ""
    var createdAt: Date = Date()

    init(name: String, keyType: String, publicKey: String) {
        self.name = name
        self.keyType = keyType
        self.publicKey = publicKey
    }

    var privateKeyAccount: String { "key-private-\(id.uuidString)" }
    var passphraseAccount: String { "key-passphrase-\(id.uuidString)" }
}

/// A snapshot of everything a session needs to connect, so connection code never
/// touches SwiftData objects off the main actor.
struct ConnectionTarget: Sendable, Hashable {
    var hostID: UUID
    var title: String
    var hostname: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    var connectionProtocol: ConnectionProtocol
    var passwordAccount: String
    var keyID: UUID?
    var moshServerCommand: String
    var tmuxSession: String

    init(host: Host) {
        hostID = host.id
        title = host.displayName
        hostname = host.hostname
        port = host.port
        username = host.username
        authMethod = host.authMethod
        connectionProtocol = host.connectionProtocol
        passwordAccount = host.passwordAccount
        keyID = host.keyID
        moshServerCommand = host.moshServerCommand
        tmuxSession = host.tmuxSession
    }

    /// The tmux session to attach to, reduced to characters safe in a shell command.
    var tmuxSessionName: String? {
        let name = tmuxSession.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return name.isEmpty ? nil : name
    }

    /// The shell command that attaches to (or creates) this host's tmux session. It also makes
    /// the wheel scroll copy mode one line per notch for Conch's own clients (tmux knows them by
    /// their XTVERSION reply, "SwiftTerm …"), so a swipe follows the finger row by row; other
    /// clients keep tmux's default of 5. Older tmux without `client_termtype` keeps 5 for all.
    /// The leading space keeps it out of history in shells that skip such lines.
    /// `setup` (no single quotes) is typed into the first pane when the session is new:
    /// panes start their own shells, which don't see what was set in this one.
    func tmuxCommand(setup: String? = nil) -> String? {
        guard let name = tmuxSessionName else { return nil }
        let wheel = ["copy-mode", "copy-mode-vi"].flatMap { table in
            [("WheelUpPane", "scroll-up"), ("WheelDownPane", "scroll-down")].map { key, action in
                #" \; bind -T \#(table) \#(key) if -F '#{m:SwiftTerm*,#{client_termtype}}' 'select-pane ; send -X \#(action)' 'select-pane ; send -X -N 5 \#(action)'"#
            }
        }
        guard let setup else { return " tmux new-session -A -s \(name)" + wheel.joined() }
        return " tmux has-session -t '=\(name)' 2>/dev/null || tmux new-session -d -s \(name)"
            + " \\; send-keys -t '=\(name):' -l '\(setup)' \\; send-keys -t '=\(name):' Enter;"
            + " tmux attach-session -t '=\(name)'" + wheel.joined()
    }
}
