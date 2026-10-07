import AVFoundation
import Contacts
import CoreLocation
import EventKit
import Foundation
import Network
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
import IOKit.ps
#endif

/// Tools that act on the device itself: status, clipboard, screen, notifications,
/// calendar, reminders, contacts, location, speech and Shortcuts. iOS doesn't let
/// apps flip system switches (Wi‑Fi, Bluetooth, Focus…) directly; the assistant
/// runs the user's Shortcuts for those.
@MainActor
final class DeviceToolbox {
    private let confirm: (ConfirmationRequest) async -> Bool
    private let eventStore = EKEventStore()
    private let speech = AVSpeechSynthesizer()

    init(confirm: @escaping (ConfirmationRequest) async -> Bool) {
        self.confirm = confirm
    }

    static let names: Set<String> = Set(specs.map(\.name))

    static let specs: [ToolSpec] = {
        var specs = [
            ToolSpec(name: "device_status", description: "查看本机状态：设备型号、系统版本、电量和充电状态、低电量模式、发热情况、存储空间、内存、网络类型、屏幕亮度、当前时间和时区。", schema: [
                "type": "object", "properties": [:],
            ]),
            ToolSpec(name: "clipboard", description: "读取或写入剪贴板。action=get 读取，action=set 写入 text。", schema: [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["get", "set"]],
                    "text": ["type": "string"],
                ],
                "required": ["action"],
            ]),
            ToolSpec(name: "run_shortcut", description: "运行用户在“快捷指令”App 里的某个快捷指令（会请用户确认）。开关 Wi‑Fi、蓝牙、专注模式、低电量模式、调音量、切换深色模式等系统设置，都通过用户自己的快捷指令完成；如果用户还没有对应的快捷指令，告诉他怎么在“快捷指令”App 里建一个。", schema: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "快捷指令的名称，必须与 App 里的完全一致"],
                    "input": ["type": "string", "description": "传给快捷指令的文本输入，可选"],
                ],
                "required": ["name"],
            ]),
            ToolSpec(name: "open_url", description: "用系统打开链接（会请用户确认）：网页、tel: 打电话、sms: 发短信、mailto: 写邮件、maps: 地图导航等。", schema: [
                "type": "object", "properties": ["url": ["type": "string"]], "required": ["url"],
            ]),
            ToolSpec(name: "open_settings", description: platformSettingsDescription, schema: [
                "type": "object",
                "properties": ["pane": ["type": "string", "enum": .array(settingsPanes.map { .string($0.key) })]],
            ]),
            ToolSpec(name: "schedule_notification", description: "在指定时间或若干秒后发一条本地通知提醒用户。", schema: [
                "type": "object",
                "properties": [
                    "title": ["type": "string"],
                    "body": ["type": "string"],
                    "after_seconds": ["type": "integer", "description": "多少秒后提醒"],
                    "at": ["type": "string", "description": "提醒时间，ISO 8601 格式，如 2026-09-27T08:30:00+08:00；与 after_seconds 二选一"],
                ],
                "required": ["title"],
            ]),
            ToolSpec(name: "list_notifications", description: "列出还没触发的提醒通知；cancel_all=true 时全部取消。", schema: [
                "type": "object", "properties": ["cancel_all": ["type": "boolean"]],
            ]),
            ToolSpec(name: "calendar_events", description: "查看日历里的日程。", schema: [
                "type": "object",
                "properties": [
                    "from": ["type": "string", "description": "开始日期 ISO 8601，默认今天 0 点"],
                    "days": ["type": "integer", "description": "查看多少天，默认 1，最多 31"],
                ],
            ]),
            ToolSpec(name: "create_calendar_event", description: "在日历里新建日程（会请用户确认）。", schema: [
                "type": "object",
                "properties": [
                    "title": ["type": "string"],
                    "start": ["type": "string", "description": "ISO 8601"],
                    "end": ["type": "string", "description": "ISO 8601，默认开始后 1 小时"],
                    "location": ["type": "string"],
                    "notes": ["type": "string"],
                    "alert_minutes_before": ["type": "integer"],
                ],
                "required": ["title", "start"],
            ]),
            ToolSpec(name: "reminders", description: "查看“提醒事项”里未完成的事项。", schema: [
                "type": "object", "properties": ["list": ["type": "string", "description": "列表名称，可选"]],
            ]),
            ToolSpec(name: "create_reminder", description: "新建一条提醒事项（会请用户确认）。", schema: [
                "type": "object",
                "properties": [
                    "title": ["type": "string"],
                    "due": ["type": "string", "description": "到期时间 ISO 8601，可选；有到期时间时会按时提醒"],
                    "notes": ["type": "string"],
                    "list": ["type": "string"],
                ],
                "required": ["title"],
            ]),
            ToolSpec(name: "complete_reminder", description: "把一条提醒事项标记为完成。", schema: [
                "type": "object", "properties": ["title": ["type": "string"]], "required": ["title"],
            ]),
            ToolSpec(name: "search_contacts", description: "按姓名搜索通讯录，返回电话和邮箱（会请用户确认）。", schema: [
                "type": "object", "properties": ["name": ["type": "string"]], "required": ["name"],
            ]),
            ToolSpec(name: "current_location", description: "获取当前位置（经纬度和大致地址）。", schema: [
                "type": "object", "properties": [:],
            ]),
            ToolSpec(name: "speak", description: "用语音朗读一段文字。", schema: [
                "type": "object",
                "properties": [
                    "text": ["type": "string"],
                    "language": ["type": "string", "description": "如 zh-CN、en-US，默认跟随文字"],
                ],
                "required": ["text"],
            ]),
        ]
        #if os(iOS)
        specs += [
            ToolSpec(name: "set_brightness", description: "调节屏幕亮度（0 到 1）。", schema: [
                "type": "object", "properties": ["level": ["type": "number"]], "required": ["level"],
            ]),
            ToolSpec(name: "flashlight", description: "打开或关闭手电筒，level 为亮度 0.1 到 1。", schema: [
                "type": "object",
                "properties": ["on": ["type": "boolean"], "level": ["type": "number"]],
                "required": ["on"],
            ]),
        ]
        #endif
        return specs
    }()

    static func activityLabel(for call: ToolCall) -> String? {
        switch call.name {
        case "device_status": String(localized: "查看设备状态")
        case "clipboard": call.input["action"]?.string == "set" ? String(localized: "写入剪贴板") : String(localized: "读取剪贴板")
        case "run_shortcut": String(localized: "运行快捷指令：\(call.input["name"]?.string ?? "")")
        case "open_url": String(localized: "打开 \(call.input["url"]?.string ?? "")")
        case "open_settings": String(localized: "打开系统设置")
        case "schedule_notification": String(localized: "设置提醒：\(call.input["title"]?.string ?? "")")
        case "list_notifications": String(localized: "查看提醒通知")
        case "calendar_events": String(localized: "查看日程")
        case "create_calendar_event": String(localized: "新建日程：\(call.input["title"]?.string ?? "")")
        case "reminders": String(localized: "查看提醒事项")
        case "create_reminder": String(localized: "新建提醒事项：\(call.input["title"]?.string ?? "")")
        case "complete_reminder": String(localized: "完成提醒事项：\(call.input["title"]?.string ?? "")")
        case "search_contacts": String(localized: "搜索联系人：\(call.input["name"]?.string ?? "")")
        case "current_location": String(localized: "获取位置")
        case "speak": String(localized: "朗读")
        case "set_brightness": String(localized: "调节亮度")
        case "flashlight": call.input["on"]?.bool == true ? String(localized: "打开手电筒") : String(localized: "关闭手电筒")
        default: nil
        }
    }

    struct ToolError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    func execute(_ name: String, _ input: JSONValue) async throws -> String {
        switch name {
        case "device_status": return await deviceStatus()
        case "clipboard": return try clipboard(input)
        case "run_shortcut": return try await runShortcut(input)
        case "open_url": return try await openURL(input)
        case "open_settings": return try openSettings(input)
        case "schedule_notification": return try await scheduleNotification(input)
        case "list_notifications": return await listNotifications(input)
        case "calendar_events": return try await calendarEvents(input)
        case "create_calendar_event": return try await createEvent(input)
        case "reminders": return try await reminders(input)
        case "create_reminder": return try await createReminder(input)
        case "complete_reminder": return try await completeReminder(input)
        case "search_contacts": return try await searchContacts(input)
        case "current_location": return try await currentLocation()
        case "speak": return speak(input)
        #if os(iOS)
        case "set_brightness": return try setBrightness(input)
        case "flashlight": return try flashlight(input)
        #endif
        default: throw ToolError("没有这个工具：\(name)")
        }
    }

    // MARK: Status

    private func deviceStatus() async -> String {
        var lines: [String] = []
        let process = ProcessInfo.processInfo
        #if os(iOS)
        let device = UIDevice.current
        lines.append(String(localized: "设备：\(device.model)（\(Self.hardwareModel())），\(device.systemName) \(device.systemVersion)，名称“\(device.name)”"))
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        let state = switch device.batteryState {
        case .charging: String(localized: "充电中")
        case .full: String(localized: "已充满")
        case .unplugged: String(localized: "未充电")
        default: String(localized: "未知")
        }
        lines.append(level >= 0 ? String(localized: "电量：\(Int(level * 100))%，\(state)") : String(localized: "电量：无法读取（模拟器）"))
        lines.append(String(localized: "屏幕亮度：\(Int((Self.screen?.brightness ?? 0) * 100))%"))
        #else
        lines.append(String(localized: "设备：Mac（\(Self.hardwareModel())），macOS \(process.operatingSystemVersionString)，名称“\(Foundation.Host.current().localizedName ?? "")”"))
        lines.append(Self.macBattery())
        #endif
        lines.append(String(localized: "低电量模式：\(process.isLowPowerModeEnabled ? "开" : "关")"))
        let thermal = switch process.thermalState {
        case .nominal: String(localized: "正常")
        case .fair: String(localized: "略热")
        case .serious: String(localized: "较热，系统可能降频")
        case .critical: String(localized: "过热")
        @unknown default: String(localized: "未知")
        }
        lines.append(String(localized: "发热：\(thermal)"))
        if let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
           let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacityForImportantUsage {
            lines.append(String(localized: "存储：可用 \(Self.bytes(free)) / 共 \(Self.bytes(Int64(total)))"))
        }
        lines.append(String(localized: "内存：\(Self.bytes(Int64(process.physicalMemory)))"))
        lines.append(String(localized: "网络：\(await Self.networkDescription())"))
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        formatter.locale = Locale(identifier: "zh_CN")
        lines.append(String(localized: "现在：\(formatter.string(from: .now))，时区 \(TimeZone.current.identifier)，语言 \(Locale.preferredLanguages.first ?? "")"))
        return lines.joined(separator: "\n")
    }

    private static func hardwareModel() -> String {
        var size = 0
        let key = { () -> String in
            #if os(iOS)
            "hw.machine"
            #else
            "hw.model"
            #endif
        }()
        sysctlbyname(key, nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname(key, &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    #if os(macOS)
    private static func macBattery() -> String {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return String(localized: "电量：无电池（台式机）") }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int else { continue }
            let charging = description[kIOPSIsChargingKey] as? Bool == true
            let plugged = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return String(localized: "电量：\(capacity)%，\(charging ? "充电中" : plugged ? "已接电源" : "使用电池")")
        }
        return String(localized: "电量：无电池（台式机）")
    }
    #endif

    private static func networkDescription() async -> String {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                guard path.status == .satisfied else { return continuation.resume(returning: String(localized: "未连接")) }
                var kinds: [String] = []
                if path.usesInterfaceType(.wifi) { kinds.append("Wi‑Fi") }
                if path.usesInterfaceType(.cellular) { kinds.append(String(localized: "蜂窝数据")) }
                if path.usesInterfaceType(.wiredEthernet) { kinds.append(String(localized: "有线")) }
                if path.usesInterfaceType(.other) { kinds.append(String(localized: "VPN/其他")) }
                var text = kinds.isEmpty ? String(localized: "已连接") : kinds.joined(separator: " + ")
                if path.isConstrained { text += String(localized: "（低数据模式）") }
                if path.isExpensive { text += String(localized: "（按流量计费）") }
                continuation.resume(returning: text)
            }
            monitor.start(queue: .global(qos: .utility))
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    #if os(iOS)
    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }
    #endif

    // MARK: Clipboard

    private func clipboard(_ input: JSONValue) throws -> String {
        if input["action"]?.string == "set" {
            guard let text = input["text"]?.string else { throw ToolError("需要 text") }
            #if os(iOS)
            UIPasteboard.general.string = text
            #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #endif
            return String(localized: "已复制到剪贴板（\(text.count) 个字符）")
        }
        #if os(iOS)
        let text = UIPasteboard.general.string
        #else
        let text = NSPasteboard.general.string(forType: .string)
        #endif
        guard let text, !text.isEmpty else { return String(localized: "剪贴板里没有文字") }
        return String(localized: "剪贴板内容：\n\(text.clipped(to: 4000))")
    }

    // MARK: Opening things

    private func open(_ url: URL) async -> Bool {
        #if os(iOS)
        return await UIApplication.shared.open(url)
        #else
        return NSWorkspace.shared.open(url)
        #endif
    }

    private func runShortcut(_ input: JSONValue) async throws -> String {
        guard let name = input["name"]?.string?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { throw ToolError("需要快捷指令名称") }
        let text = input["input"]?.string
        guard await confirm(ConfirmationRequest(title: String(localized: "运行快捷指令“\(name)”？"), detail: text.map { String(localized: "输入：\($0)") } ?? "", isDestructive: false)) else {
            return String(localized: "用户取消了")
        }
        var components = URLComponents(string: "shortcuts://run-shortcut")!
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        if let text, !text.isEmpty {
            components.queryItems? += [URLQueryItem(name: "input", value: "text"), URLQueryItem(name: "text", value: text)]
        }
        guard let url = components.url, await open(url) else { throw ToolError("无法打开“快捷指令”App") }
        return String(localized: "已交给“快捷指令”运行“\(name)”。如果名称不存在，快捷指令 App 会提示找不到。")
    }

    private func openURL(_ input: JSONValue) async throws -> String {
        guard let string = input["url"]?.string, let url = URL(string: string), url.scheme != nil else { throw ToolError("链接无效") }
        guard await confirm(ConfirmationRequest(title: String(localized: "打开这个链接？"), detail: "", code: string, isDestructive: false)) else {
            return String(localized: "用户取消了")
        }
        return await open(url) ? String(localized: "已打开") : String(localized: "系统无法打开这个链接")
    }

    #if os(iOS)
    private static let settingsPanes: [String: String] = ["app": UIApplication.openSettingsURLString]
    private static let platformSettingsDescription = "打开“设置”里 Conch 自己的设置页（权限、通知等）。iOS 不允许 App 直接打开其他设置页。"
    #else
    private static let settingsPanes: [String: String] = [
        "remote_login": "x-apple.systempreferences:com.apple.Sharing-Settings.extension?Services_RemoteLogin",
        "sharing": "x-apple.systempreferences:com.apple.Sharing-Settings.extension",
        "network": "x-apple.systempreferences:com.apple.Network-Settings.extension",
        "wifi": "x-apple.systempreferences:com.apple.wifi-settings-extension",
        "bluetooth": "x-apple.systempreferences:com.apple.BluetoothSettings",
        "displays": "x-apple.systempreferences:com.apple.Displays-Settings.extension",
        "sound": "x-apple.systempreferences:com.apple.Sound-Settings.extension",
        "battery": "x-apple.systempreferences:com.apple.Battery-Settings.extension",
        "privacy": "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
        "notifications": "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
    ]
    private static let platformSettingsDescription = "打开 Mac 的系统设置页面。remote_login 是“远程登录”（让手机通过 SSH 连上这台 Mac 时需要打开）。"
    #endif

    private func openSettings(_ input: JSONValue) throws -> String {
        let key = input["pane"]?.string ?? Self.settingsPanes.keys.sorted().first!
        guard let string = Self.settingsPanes[key], let url = URL(string: string) else { throw ToolError("没有这个设置页") }
        Task { _ = await open(url) }
        return String(localized: "已打开设置")
    }

    // MARK: Notifications

    private func scheduleNotification(_ input: JSONValue) async throws -> String {
        let center = UNUserNotificationCenter.current()
        guard try await center.requestAuthorization(options: [.alert, .sound, .badge]) else {
            throw ToolError("没有通知权限。请在系统设置里允许 Conch 发送通知。")
        }
        let content = UNMutableNotificationContent()
        content.title = input["title"]?.string ?? String(localized: "提醒")
        content.body = input["body"]?.string ?? ""
        content.sound = .default

        let trigger: UNNotificationTrigger
        let when: Date
        if let at = input["at"]?.string {
            guard let date = Self.parseDate(at) else { throw ToolError("时间格式不对：\(at)") }
            guard date > .now else { throw ToolError("这个时间已经过去了") }
            when = date
            trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date), repeats: false)
        } else {
            let seconds = max(input["after_seconds"]?.int ?? 60, 1)
            when = Date.now.addingTimeInterval(TimeInterval(seconds))
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false)
        }
        try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger))
        return String(localized: "已设置提醒，将在 \(Self.describe(when)) 通知“\(content.title)”")
    }

    private func listNotifications(_ input: JSONValue) async -> String {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        if input["cancel_all"]?.bool == true {
            center.removeAllPendingNotificationRequests()
            return String(localized: "已取消 \(pending.count) 条提醒")
        }
        guard !pending.isEmpty else { return String(localized: "没有待触发的提醒") }
        return pending.map { request in
            let date = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                ?? (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
            return "- \(request.content.title)\(date.map { "（\(Self.describe($0))）" } ?? "")"
        }.joined(separator: "\n")
    }

    // MARK: Calendar & reminders

    private func requestEvents() async throws {
        guard try await eventStore.requestFullAccessToEvents() else {
            throw ToolError("没有日历权限。请在系统设置 › 隐私与安全性 › 日历 里允许 Conch。")
        }
    }

    private func requestReminders() async throws {
        guard try await eventStore.requestFullAccessToReminders() else {
            throw ToolError("没有提醒事项权限。请在系统设置 › 隐私与安全性 › 提醒事项 里允许 Conch。")
        }
    }

    private func calendarEvents(_ input: JSONValue) async throws -> String {
        try await requestEvents()
        let start = input["from"]?.string.flatMap(Self.parseDate) ?? Calendar.current.startOfDay(for: .now)
        let days = min(max(input["days"]?.int ?? 1, 1), 31)
        let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start
        let events = eventStore.events(matching: eventStore.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
        guard !events.isEmpty else { return String(localized: "\(Self.describe(start)) 起 \(days) 天内没有日程") }
        return events.prefix(80).map { event in
            var line = String(localized: "- \(event.isAllDay ? "全天" : Self.describe(event.startDate))：\(event.title ?? "（无标题）")")
            if let location = event.location, !location.isEmpty { line += " @\(location)" }
            line += "［\(event.calendar.title)］"
            return line
        }.joined(separator: "\n")
    }

    private func createEvent(_ input: JSONValue) async throws -> String {
        guard let title = input["title"]?.string, let start = input["start"]?.string.flatMap(Self.parseDate) else {
            throw ToolError("需要标题和有效的开始时间")
        }
        let end = input["end"]?.string.flatMap(Self.parseDate) ?? start.addingTimeInterval(3600)
        guard await confirm(ConfirmationRequest(title: String(localized: "添加日程“\(title)”？"), detail: "\(Self.describe(start)) – \(Self.describe(end))", isDestructive: false)) else {
            return String(localized: "用户取消了")
        }
        try await requestEvents()
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.location = input["location"]?.string
        event.notes = input["notes"]?.string
        if let minutes = input["alert_minutes_before"]?.int { event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-minutes * 60))) }
        guard let calendar = eventStore.defaultCalendarForNewEvents else { throw ToolError("没有可写入的日历") }
        event.calendar = calendar
        try eventStore.save(event, span: .thisEvent)
        return String(localized: "已添加到“\(calendar.title)”：\(title)，\(Self.describe(start))")
    }

    private func fetchReminders(_ predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    private func reminderLists(named name: String?) -> [EKCalendar]? {
        guard let name, !name.isEmpty else { return nil }
        let lists = eventStore.calendars(for: .reminder).filter { $0.title.localizedCaseInsensitiveContains(name) }
        return lists.isEmpty ? nil : lists
    }

    private func reminders(_ input: JSONValue) async throws -> String {
        try await requestReminders()
        let predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil,
                                                                   calendars: reminderLists(named: input["list"]?.string))
        let items = await fetchReminders(predicate)
        guard !items.isEmpty else { return String(localized: "没有未完成的提醒事项") }
        return items.prefix(80).map { reminder in
            var line = "- \(reminder.title ?? "")"
            if let due = reminder.dueDateComponents?.date { line += String(localized: "（\(Self.describe(due)) 到期）") }
            line += "［\(reminder.calendar.title)］"
            return line
        }.joined(separator: "\n")
    }

    private func createReminder(_ input: JSONValue) async throws -> String {
        guard let title = input["title"]?.string, !title.isEmpty else { throw ToolError("需要标题") }
        let due = input["due"]?.string.flatMap(Self.parseDate)
        guard await confirm(ConfirmationRequest(title: String(localized: "添加提醒事项“\(title)”？"), detail: due.map { String(localized: "\(Self.describe($0)) 到期") } ?? "", isDestructive: false)) else {
            return String(localized: "用户取消了")
        }
        try await requestReminders()
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.notes = input["notes"]?.string
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        guard let list = reminderLists(named: input["list"]?.string)?.first ?? eventStore.defaultCalendarForNewReminders() else {
            throw ToolError("没有可写入的提醒事项列表")
        }
        reminder.calendar = list
        try eventStore.save(reminder, commit: true)
        return String(localized: "已添加到“\(list.title)”：\(title)")
    }

    private func completeReminder(_ input: JSONValue) async throws -> String {
        guard let title = input["title"]?.string, !title.isEmpty else { throw ToolError("需要标题") }
        try await requestReminders()
        let items = await fetchReminders(eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil))
        let matches = items.filter { ($0.title ?? "").localizedCaseInsensitiveContains(title) }
        guard let reminder = matches.first else { throw ToolError("找不到未完成的“\(title)”") }
        if matches.count > 1, !matches.contains(where: { $0.title == title }) {
            throw ToolError("有多条匹配：\(matches.prefix(5).compactMap(\.title).joined(separator: "、"))，请说完整名称")
        }
        let target = matches.first { $0.title == title } ?? reminder
        target.isCompleted = true
        try eventStore.save(target, commit: true)
        return String(localized: "已完成：\(target.title ?? title)")
    }

    // MARK: Contacts

    private func searchContacts(_ input: JSONValue) async throws -> String {
        guard let name = input["name"]?.string, !name.isEmpty else { throw ToolError("需要姓名") }
        guard await confirm(ConfirmationRequest(title: String(localized: "在通讯录里搜索“\(name)”？"), detail: String(localized: "找到的电话和邮箱会发送给 AI 服务。"), isDestructive: false)) else {
            return String(localized: "用户取消了")
        }
        let store = CNContactStore()
        guard try await store.requestAccess(for: .contacts) else {
            throw ToolError("没有通讯录权限。请在系统设置 › 隐私与安全性 › 通讯录 里允许 Conch。")
        }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
                    CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let contacts = try await Task.detached {
            try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)
        }.value
        guard !contacts.isEmpty else { return String(localized: "没有找到“\(name)”") }
        return contacts.prefix(10).map { contact in
            let fullName = [contact.familyName, contact.givenName].joined().trimmingCharacters(in: .whitespaces)
            let phones = contact.phoneNumbers.map(\.value.stringValue).joined(separator: "、")
            let emails = contact.emailAddresses.map { $0.value as String }.joined(separator: "、")
            var line = "- \(fullName.isEmpty ? contact.organizationName : fullName)"
            if !phones.isEmpty { line += String(localized: " 电话：\(phones)") }
            if !emails.isEmpty { line += String(localized: " 邮箱：\(emails)") }
            return line
        }.joined(separator: "\n")
    }

    // MARK: Location

    private func currentLocation() async throws -> String {
        let location = try await LocationFetcher().fetch()
        var text = String(format: String(localized: "纬度 %.5f，经度 %.5f（精度约 %.0f 米）"), location.coordinate.latitude, location.coordinate.longitude, location.horizontalAccuracy)
        if let place = try? await CLGeocoder().reverseGeocodeLocation(location).first {
            let parts = [place.country, place.administrativeArea, place.locality, place.subLocality, place.thoroughfare, place.name]
            var address: [String] = []
            for part in parts.compactMap({ $0 }) where !address.contains(part) { address.append(part) }
            if !address.isEmpty { text += String(localized: "\n地址：\(address.joined(separator: " "))") }
        }
        return text
    }

    // MARK: Speech & screen

    private func speak(_ input: JSONValue) -> String {
        guard let text = input["text"]?.string, !text.isEmpty else { return String(localized: "没有要朗读的文字") }
        let utterance = AVSpeechUtterance(string: text)
        let language = input["language"]?.string ?? (text.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF } ? "zh-CN" : "en-US")
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        speech.stopSpeaking(at: .immediate)
        speech.speak(utterance)
        return String(localized: "正在朗读")
    }

    #if os(iOS)
    private func setBrightness(_ input: JSONValue) throws -> String {
        guard case .number(let level)? = input["level"] else { throw ToolError("需要 level") }
        guard let screen = Self.screen else { throw ToolError("找不到屏幕") }
        screen.brightness = CGFloat(min(max(level, 0), 1))
        return String(localized: "亮度已调到 \(Int(screen.brightness * 100))%")
    }

    private func flashlight(_ input: JSONValue) throws -> String {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { throw ToolError("这台设备没有手电筒") }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if input["on"]?.bool == true {
            var level: Float = 1
            if case .number(let value)? = input["level"] { level = Float(min(max(value, 0.1), 1)) }
            try device.setTorchModeOn(level: level)
            return String(localized: "手电筒已打开")
        }
        device.torchMode = .off
        return String(localized: "手电筒已关闭")
    }
    #endif

    // MARK: Dates

    static func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        let full = ISO8601DateFormatter()
        if let date = full.date(from: trimmed) { return date }
        // Without a time zone, read it as local time.
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    static func describe(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year) ? String(localized: "M月d日 EEE HH:mm") : String(localized: "yyyy年M月d日 HH:mm")
        return formatter.string(from: date)
    }
}

/// One-shot location lookup that asks for permission the first time.
@MainActor
private final class LocationFetcher: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    func fetch() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .denied, .restricted:
                finish(.failure(DeviceToolbox.ToolError("没有定位权限。请在系统设置 › 隐私与安全性 › 定位服务 里允许 Conch。")))
            default:
                manager.requestLocation()
            }
            // Don't hang the assistant if nothing comes back.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.finish(.failure(DeviceToolbox.ToolError("定位超时")))
            }
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        manager.delegate = nil
        continuation.resume(with: result)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        switch manager.authorizationStatus {
        case .notDetermined: break
        case .denied, .restricted: finish(.failure(DeviceToolbox.ToolError("用户没有允许定位")))
        default: manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.last { finish(.success(location)) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(error))
    }
}
