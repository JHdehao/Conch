import Foundation

/// A deliberately cautious guess at whether a shell command can destroy data,
/// lock the user out or take a server down. In the assistant's auto mode these
/// still ask first; everything else runs without a prompt.
enum CommandRisk {
    private static let patterns: [NSRegularExpression] = [
        // Anything run with elevated privileges.
        #"(^|[\s;&|(`])(sudo|doas|su)(\s|$)"#,
        // Deleting, overwriting or reformatting data.
        #"(^|[\s;&|(`])(rm|rmdir|shred|dd|mkfs(\.\w+)?|fdisk|parted|wipefs|truncate|mv)\s"#,
        #"(?<![0-9&>])>(?!>)\s*(?!/dev/null)[^\s&|;]"#,
        #"(^|[\s;&|(`])find\s.*\s-(delete|exec\s+rm)"#,
        // Stopping the machine or its services.
        #"(^|[\s;&|(`])(shutdown|reboot|halt|poweroff)\b"#,
        #"(^|[\s;&|(`])init\s+[06]\b"#,
        #"(^|[\s;&|(`])(kill|pkill|killall)\s"#,
        #"systemctl\s+(stop|disable|mask|restart|poweroff|reboot|halt)"#,
        #"(^|[\s;&|(`])(service|launchctl)\s+\S+\s+(stop|unload|bootout)"#,
        // Permissions, users and firewalls (easy ways to lock yourself out).
        #"(^|[\s;&|(`])(chmod|chown|chgrp)\s+(-\w*[rR]|--recursive)"#,
        #"(^|[\s;&|(`])(iptables|ip6tables|nft|ufw|firewall-cmd|pfctl)\s"#,
        #"(^|[\s;&|(`])(userdel|usermod|groupdel|passwd|visudo)\b"#,
        #"sshd_config|authorized_keys"#,
        #"crontab\s+-r"#,
        // Irreversible git, container and package operations.
        #"git\s+(reset\s+--hard|clean\s+-\w*f|push\s+.*(-f\b|--force))"#,
        #"docker\s+(rm|rmi|system\s+prune|volume\s+(rm|prune)|compose\s+down)"#,
        #"(apt|apt-get|yum|dnf|pacman|brew|pip3?|npm|pnpm|yarn)\s+(remove|purge|uninstall|autoremove|-R)"#,
        // Running a script straight from the network.
        #"\|\s*(sudo\s+)?(sh|bash|zsh|python3?)\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func isDangerous(_ command: String) -> Bool {
        let range = NSRange(command.startIndex..., in: command)
        return patterns.contains { $0.firstMatch(in: command, range: range) != nil }
    }
}
