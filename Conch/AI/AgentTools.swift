import Foundation
import SwiftData

/// Everything the assistant can do in the app. Each tool returns a short text
/// result for the model; risky ones ask the user first.
@MainActor
final class AgentToolbox {
    private let modelContext: ModelContext
    private let workspace: Workspace
    private let openHost: (Host) -> Void
    private let openAgents: () -> Void
    let confirm: (ConfirmationRequest) async -> Bool
    /// Shows question cards and waits; nil when the user skips.
    private let ask: ([AgentQuestion]) async -> [String: [String]]?
    /// Puts a file (path under Application Support) into the chat for the user.
    let deliverFile: (String) -> Void
    /// The files in this conversation (attachments, handed-over files), oldest first.
    let deviceFiles: () -> [DeviceFile]
    private let device: DeviceToolbox
    private let browser: BrowserToolbox
    private let web = WebToolbox()
    private let scripts: ScriptToolbox
    private let tailscaleTools: TailscaleToolbox
    private let revealWorkspace: () -> Void

    init(
        modelContext: ModelContext,
        workspace: Workspace,
        openHost: @escaping (Host) -> Void,
        openAgents: @escaping () -> Void,
        revealWorkspace: @escaping () -> Void,
        deliverFile: @escaping (String) -> Void,
        deviceFiles: @escaping () -> [DeviceFile],
        ask: @escaping ([AgentQuestion]) async -> [String: [String]]?,
        confirm: @escaping (ConfirmationRequest) async -> Bool
    ) {
        self.ask = ask
        self.deviceFiles = deviceFiles
        self.modelContext = modelContext
        self.workspace = workspace
        self.openHost = openHost
        self.openAgents = openAgents
        self.confirm = confirm
        self.deliverFile = deliverFile
        device = DeviceToolbox(confirm: confirm)
        scripts = ScriptToolbox(confirm: confirm)
        tailscaleTools = TailscaleToolbox(confirm: confirm)
        self.revealWorkspace = revealWorkspace
        browser = BrowserToolbox(workspace: workspace, reveal: revealWorkspace, confirm: confirm)
    }

    // MARK: Definitions

    /// Files on this device come first: the model reaches for what's listed first.
    static let specs: [ToolSpec] = askSpecs + connectionSpecs + DeviceToolbox.specs + documentSpecs + editSpecs + manageSpecs + fileSpecs + ScriptToolbox.specs + WebToolbox.specs + TailscaleToolbox.specs + BrowserToolbox.specs

    /// What the model is offered right now: memory tools only while memory is on,
    /// web lookup only while the user allows it.
    static var currentSpecs: [ToolSpec] {
        var offered = MemoryStore.isEnabled ? specs + memorySpecs : specs
        if !WebLookup.isEnabled { offered.removeAll { WebToolbox.names.contains($0.name) } }
        return offered
    }

    private static let memorySpecs: [ToolSpec] = [
        ToolSpec(name: "remember", description: "记住一条关于用户的持久信息（偏好、环境、习惯、纠正过的做法），以后的对话都能看到。要更新已有的一条，传 replaces。", schema: [
            "type": "object",
            "properties": [
                "text": ["type": "string", "description": "一条简短的陈述句，只记一件事"],
                "replaces": ["type": "string", "description": "要改写的记忆 id，如 m3；新增时不传"],
            ],
            "required": ["text"],
        ]),
        ToolSpec(name: "forget", description: "删除一条过时或用户要求忘掉的记忆。", schema: [
            "type": "object", "properties": ["id": ["type": "string", "description": "记忆 id，如 m3"]], "required": ["id"],
        ]),
    ]

    private static let askSpecs: [ToolSpec] = [
        ToolSpec(name: "ask_user", description: "需要用户拿主意时（几种做法二选一、缺一个关键信息、确认偏好），用选项卡片问用户，比在回复里提问更方便用户回答。一次最多 4 个问题，每题 2–4 个选项，推荐项放第一个并在 label 末尾标「（推荐）」。用户总能自己填答案。能自己查到或决定的事不要问。", schema: [
            "type": "object",
            "properties": [
                "questions": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "question": ["type": "string", "description": "完整的问题，以问号结尾"],
                            "header": ["type": "string", "description": "很短的标签，如「部署方式」"],
                            "multi_select": ["type": "boolean", "description": "可以多选时为 true"],
                            "options": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "label": ["type": "string", "description": "选项，1–5 个词"],
                                        "description": ["type": "string", "description": "这个选项意味着什么、有什么取舍"],
                                    ],
                                    "required": ["label"],
                                ],
                            ],
                        ],
                        "required": ["question", "options"],
                    ],
                ],
            ],
            "required": ["questions"],
        ]),
    ]

    /// The user's answers as `问题：答案` lines, or a note that they skipped.
    private func askUser(_ input: JSONValue) async throws -> String {
        let questions = (input["questions"]?.array ?? []).prefix(4).compactMap { question -> AgentQuestion? in
            guard let text = question["question"]?.string else { return nil }
            let options = (question["options"]?.array ?? []).compactMap { option in
                option["label"]?.string.map { AgentQuestion.Option(label: $0, description: option["description"]?.string ?? "") }
            }
            return AgentQuestion(id: text, header: question["header"]?.string ?? "", text: text, options: options,
                                 multiSelect: question["multi_select"]?.bool ?? false, allowsOther: true, isSecret: false)
        }
        guard !questions.isEmpty else { throw ToolError(String(localized: "没有可问的问题")) }
        guard let answers = await ask(Array(questions)) else {
            return String(localized: "用户没有回答，选择了跳过。按你的判断继续，或在回复里说明需要什么。")
        }
        return questions.map { "\($0.text)：\((answers[$0.id] ?? []).joined(separator: "、"))" }.joined(separator: "\n")
    }

    private static let connectionSpecs: [ToolSpec] = {
        let serverRef: JSONValue = ["type": "string", "description": "服务器的 id、名称或主机地址"]
        let terminalRef: JSONValue = ["type": "string", "description": "服务器的 id、名称或主机地址"]
        let themeIDs: JSONValue = .array(TerminalTheme.all.map { .string($0.id) })
        return [
            ToolSpec(name: "get_app_state", description: "查看当前状态：所有服务器、打开的终端会话及其连接状态和最近的错误、外观设置。回答问题或排查故障前先调用。", schema: [
                "type": "object", "properties": [:],
            ]),
            ToolSpec(name: "add_server", description: "添加一台服务器。不要在聊天里索要密码：留空后，用户连接时会在安全输入框里输入。", schema: [
                "type": "object",
                "properties": [
                    "hostname": ["type": "string", "description": "域名或 IP"],
                    "username": ["type": "string", "description": "登录用户名，如 root"],
                    "port": ["type": "integer", "description": "SSH 端口，默认 22"],
                    "name": ["type": "string", "description": "显示名称"],
                    "group": ["type": "string", "description": "分组，可选"],
                    "protocol": ["type": "string", "enum": ["ssh", "mosh"]],
                    "auth_method": ["type": "string", "enum": ["password", "key"]],
                    "key_name": ["type": "string", "description": "使用密钥认证时的密钥名称"],
                    "color": ["type": "string", "enum": .array(HostTint.allCases.map { .string($0.rawValue) })],
                ],
                "required": ["hostname", "username"],
            ]),
            ToolSpec(name: "update_server", description: "修改服务器设置，只传需要改的字段。", schema: [
                "type": "object",
                "properties": [
                    "server": serverRef,
                    "hostname": ["type": "string"], "username": ["type": "string"], "port": ["type": "integer"],
                    "name": ["type": "string"], "group": ["type": "string"],
                    "protocol": ["type": "string", "enum": ["ssh", "mosh"]],
                    "auth_method": ["type": "string", "enum": ["password", "key"]],
                    "key_name": ["type": "string"],
                    "color": ["type": "string", "enum": .array(HostTint.allCases.map { .string($0.rawValue) })],
                ],
                "required": ["server"],
            ]),
            ToolSpec(name: "delete_server", description: "删除服务器（会请用户确认）。", schema: [
                "type": "object", "properties": ["server": serverRef], "required": ["server"],
            ]),
            ToolSpec(name: "connect", description: "打开一个终端标签连接服务器，最多等待 20 秒并返回结果（成功、失败原因、或正在等用户输入密码/确认指纹）。", schema: [
                "type": "object", "properties": ["server": terminalRef], "required": ["server"],
            ]),
            ToolSpec(name: "disconnect", description: "断开某台服务器的所有会话。", schema: [
                "type": "object", "properties": ["server": serverRef], "required": ["server"],
            ]),
            ToolSpec(name: "diagnose_connection", description: "逐层诊断连接问题：DNS、TCP 端口、SSH 服务、主机密钥、登录，并返回每一步的结果。连不上时优先调用。", schema: [
                "type": "object", "properties": ["server": serverRef], "required": ["server"],
            ]),
            ToolSpec(name: "run_remote_command", description: "在服务器上执行一条命令并返回输出（新开独立连接，不影响终端）。用于检查状态或修复问题。每次执行前都会请用户确认。需要已保存的密码或密钥。", schema: [
                "type": "object",
                "properties": [
                    "server": serverRef,
                    "command": ["type": "string", "description": "要执行的 shell 命令"],
                    "reason": ["type": "string", "description": "用一句话向用户说明为什么要执行"],
                ],
                "required": ["server", "command", "reason"],
            ]),
            ToolSpec(name: "read_terminal", description: "读取当前（或指定服务器的）终端屏幕上最近的内容，用来查看报错或命令输出。", schema: [
                "type": "object",
                "properties": ["server": terminalRef, "lines": ["type": "integer", "description": "行数，默认 60"]],
            ]),
            ToolSpec(name: "type_in_terminal", description: "在当前终端里输入文字（会请用户确认）。press_enter=true 时回车执行。", schema: [
                "type": "object",
                "properties": [
                    "text": ["type": "string"],
                    "press_enter": ["type": "boolean"],
                    "server": terminalRef,
                ],
                "required": ["text"],
            ]),
            ToolSpec(name: "set_appearance", description: "修改终端外观，只传需要改的字段。可用主题：\(TerminalTheme.all.map { "\($0.id)（\($0.name)）" }.joined(separator: "、"))。", schema: [
                "type": "object",
                "properties": [
                    "theme": ["type": "string", "enum": themeIDs, "description": "同时设为深色和浅色主题，并关闭跟随系统"],
                    "dark_theme": ["type": "string", "enum": themeIDs],
                    "light_theme": ["type": "string", "enum": themeIDs],
                    "follow_system": ["type": "boolean"],
                    "font": ["type": "string", "enum": .array(TerminalFont.allCases.map { .string($0.rawValue) })],
                    "font_size": ["type": "integer", "description": "9 到 28"],
                    "cursor": ["type": "string", "enum": .array(CursorShape.allCases.map { .string($0.rawValue) })],
                    "cursor_blink": ["type": "boolean"],
                    "opacity": ["type": "number", "description": "Mac 窗口不透明度 0.5 到 1"],
                ],
            ]),
            ToolSpec(name: "generate_key", description: "生成一把新的 Ed25519 SSH 密钥，返回公钥。", schema: [
                "type": "object", "properties": ["name": ["type": "string"]], "required": ["name"],
            ]),
            ToolSpec(name: "setup_key_login", description: "配置免密登录：把指定密钥（不填则新建）的公钥追加到服务器的 ~/.ssh/authorized_keys，验证能用密钥登录后，把这台服务器改成密钥认证（会请用户确认）。服务器需要当前能登录（已保存密码）。", schema: [
                "type": "object",
                "properties": ["server": serverRef, "key_name": ["type": "string"]],
                "required": ["server"],
            ]),
            ToolSpec(name: "forget_host_key", description: "删除某台服务器已记录的主机密钥指纹（服务器重装后指纹变化时使用，会请用户确认）。", schema: [
                "type": "object", "properties": ["server": serverRef], "required": ["server"],
            ]),
            ToolSpec(name: "ask_coding_agent", description: "把编程任务交给那台电脑上的 Claude Code 或 Codex 去做（在“AI 编程”里新开一个对话，会请用户确认），等它完成后返回它的回复。适合写代码、改 bug、跑测试、解释项目等需要在项目里动手的事。", schema: [
                "type": "object",
                "properties": [
                    "server": serverRef,
                    "agent": ["type": "string", "enum": ["claude", "codex"], "description": "默认 claude"],
                    "directory": ["type": "string", "description": "项目目录，如 ~/code/app；默认主目录"],
                    "prompt": ["type": "string", "description": "交给它的任务，写清楚目标"],
                    "wait_seconds": ["type": "integer", "description": "最多等多久（秒），默认 120，最多 600；超时后它会继续在后台运行"],
                ],
                "required": ["server", "prompt"],
            ]),
        ]
    }()

    /// Short, human-readable label shown in the chat while a tool runs.
    func activityLabel(for call: ToolCall) -> String {
        WebToolbox.activityLabel(for: call) ?? ScriptToolbox.activityLabel(for: call) ?? TailscaleToolbox.activityLabel(for: call) ?? Self.documentActivityLabel(for: call) ?? Self.editActivityLabel(for: call) ?? Self.manageActivityLabel(for: call) ?? Self.fileActivityLabel(for: call) ?? browser.activityLabel(for: call) ?? Self.activityLabel(for: call)
    }

    private static func activityLabel(for call: ToolCall) -> String {
        let server = call.input["server"]?.string ?? call.input["hostname"]?.string ?? ""
        switch call.name {
        case "get_app_state": return String(localized: "查看状态")
        case "add_server": return String(localized: "添加服务器 \(server)")
        case "update_server": return String(localized: "修改服务器 \(server)")
        case "delete_server": return String(localized: "删除服务器 \(server)")
        case "connect": return String(localized: "连接 \(server)")
        case "disconnect": return String(localized: "断开 \(server)")
        case "diagnose_connection": return String(localized: "诊断 \(server) 的连接")
        case "run_remote_command": return String(localized: "执行命令：\(call.input["command"]?.string ?? "")")
        case "read_terminal": return String(localized: "读取终端内容")
        case "type_in_terminal": return String(localized: "在终端输入")
        case "set_appearance": return String(localized: "调整外观")
        case "generate_key": return String(localized: "生成密钥")
        case "setup_key_login": return String(localized: "配置 \(server) 免密登录")
        case "forget_host_key": return String(localized: "删除 \(server) 的旧指纹")
        case "remember": return String(localized: "记住：\(call.input["text"]?.string?.prefix(40) ?? "")")
        case "forget": return String(localized: "忘掉记忆 \(call.input["id"]?.string ?? "")")
        case "ask_coding_agent": return String(localized: "交给 \(call.input["agent"]?.string == "codex" ? "Codex" : "Claude Code")：\(call.input["prompt"]?.string?.prefix(40) ?? "")")
        default: return DeviceToolbox.activityLabel(for: call) ?? call.name
        }
    }

    // MARK: Dispatch

    /// Read-only lookups that can run side by side within one model turn.
    static func runsConcurrently(_ call: ToolCall) -> Bool {
        WebToolbox.names.contains(call.name) || readOnlyEditTools.contains(call.name) || call.name == "search_files"
    }

    func run(_ call: ToolCall) async -> ToolOutput {
        do {
            if call.name == "browser_screenshot" {
                let shot = try await browser.screenshot(call.input, label: activityLabel(for: call))
                return ToolOutput(callID: call.id, content: shot.text, isError: false, images: [shot.image])
            }
            let text = if WebToolbox.names.contains(call.name) {
                WebLookup.isEnabled ? try await web.execute(call.name, call.input) : String(localized: "用户关闭了快速联网，请用 browser_open 在浏览器里查。")
            } else if ScriptToolbox.names.contains(call.name) {
                try await scripts.execute(call.name, call.input)
            } else if Self.documentToolNames.contains(call.name) {
                try await executeDocument(call.name, call.input)
            } else if Self.editToolNames.contains(call.name) {
                try await executeEdit(call.name, call.input)
            } else if Self.manageToolNames.contains(call.name) {
                try await executeManage(call.name, call.input)
            } else if TailscaleToolbox.names.contains(call.name) {
                try await tailscaleTools.execute(call.name, call.input)
            } else if BrowserToolbox.names.contains(call.name) {
                try await browser.execute(call.name, call.input, label: activityLabel(for: call))
            } else {
                try await execute(call.name, call.input)
            }
            return ToolOutput(callID: call.id, content: text, isError: false)
        } catch is CancellationError {
            return ToolOutput(callID: call.id, content: String(localized: "已被用户中止"), isError: true)
        } catch {
            return ToolOutput(callID: call.id, content: String(localized: "失败：\(error.localizedDescription)"), isError: true)
        }
    }

    struct ToolError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// The assistant finished answering.
    func endOfTurn() {
        browser.endOfTurn()
    }

    private func execute(_ name: String, _ input: JSONValue) async throws -> String {
        switch name {
        case "ask_user": return try await askUser(input)
        case "get_app_state": return appState()
        case "add_server": return try addServer(input)
        case "update_server": return try updateServer(input)
        case "delete_server": return try await deleteServer(input)
        case "connect": return try await connect(input)
        case "disconnect": return try disconnect(input)
        case "diagnose_connection": return try await diagnose(input)
        case "run_remote_command": return try await runRemote(input)
        case "read_terminal": return try readTerminal(input)
        case "type_in_terminal": return try await typeInTerminal(input)
        case "set_appearance": return setAppearance(input)
        case "generate_key": return try generateKey(input)
        case "setup_key_login": return try await setupKeyLogin(input)
        case "forget_host_key": return try await forgetHostKey(input)
        case "ask_coding_agent": return try await askCodingAgent(input)
        case "share_file": return try await shareFile(input)
        case "transfer_file": return try await transferFile(input)
        case "show_qr_code": return try showQRCode(input)
        case "remember":
            guard MemoryStore.isEnabled else { throw ToolError("用户关闭了记忆功能") }
            let entry = try MemoryStore.shared.remember(input["text"]?.string ?? "", replacing: input["replaces"]?.string)
            return String(localized: "已记住（\(entry.id)）")
        case "forget":
            guard MemoryStore.isEnabled else { throw ToolError("用户关闭了记忆功能") }
            try MemoryStore.shared.forget(input["id"]?.string ?? "")
            return String(localized: "已删除")
        default:
            guard DeviceToolbox.names.contains(name) else { throw ToolError("没有这个工具：\(name)") }
            return try await device.execute(name, input)
        }
    }

    // MARK: Lookups

    private var hosts: [Host] {
        (try? modelContext.fetch(FetchDescriptor<Host>(sortBy: [SortDescriptor(\.name)]))) ?? []
    }

    private var keys: [SSHKey] {
        (try? modelContext.fetch(FetchDescriptor<SSHKey>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    func host(_ input: JSONValue) throws -> Host {
        guard let ref = input["server"]?.string?.trimmingCharacters(in: .whitespaces), !ref.isEmpty else {
            throw ToolError("需要指定 server")
        }
        let all = hosts
        if let match = all.first(where: { $0.id.uuidString.caseInsensitiveCompare(ref) == .orderedSame }) { return match }
        let matches = all.filter {
            $0.displayName.caseInsensitiveCompare(ref) == .orderedSame || $0.hostname.caseInsensitiveCompare(ref) == .orderedSame
        }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { throw ToolError("有多台服务器匹配“\(ref)”，请用 id 指定") }
        let fuzzy = all.filter { $0.displayName.localizedCaseInsensitiveContains(ref) || $0.hostname.localizedCaseInsensitiveContains(ref) }
        if fuzzy.count == 1 { return fuzzy[0] }
        throw ToolError("找不到服务器“\(ref)”。现有：\(all.map(\.displayName).joined(separator: "、"))")
    }

    private func key(named name: String) throws -> SSHKey {
        guard let key = keys.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw ToolError("找不到密钥“\(name)”。现有：\(keys.map(\.name).joined(separator: "、"))")
        }
        return key
    }

    private func sessions(for host: Host) -> [TerminalSession] {
        workspace.allSessions.filter { $0.target.hostID == host.id }
    }

    private func describe(_ state: TerminalSession.State) -> String {
        switch state {
        case .idle: String(localized: "未连接")
        case .needsPassword: String(localized: "等待用户输入密码")
        case .connecting: String(localized: "连接中")
        case .connected: String(localized: "已连接")
        case .closed: String(localized: "已关闭")
        case .failed(let message): String(localized: "失败：\(message)")
        case .reconnecting(let attempt): String(localized: "断线重连中（第 \(attempt) 次）")
        }
    }

    // MARK: Tools

    private func appState() -> String {
        var lines = [String(localized: "服务器：")]
        for host in hosts {
            var line = String(localized: "- id=\(host.id.uuidString) 名称=\(host.displayName) 地址=\(host.subtitle) 协议=\(host.connectionProtocol.rawValue) 认证=\(host.authMethod.rawValue)")
            if host.authMethod == .password {
                line += Keychain.data(for: host.passwordAccount) == nil ? String(localized: "（未保存密码）") : String(localized: "（已保存密码）")
            } else if let keyID = host.keyID, let key = keys.first(where: { $0.id == keyID }) {
                line += String(localized: "（密钥 \(key.name)）")
            }
            if !host.group.isEmpty { line += String(localized: " 分组=\(host.group)") }
            lines.append(line)
        }
        if hosts.isEmpty { lines.append(String(localized: "（还没有服务器）")) }

        lines.append(String(localized: "打开的会话："))
        let focused = workspace.selectedTab?.focusedPane?.id
        for session in workspace.allSessions {
            var line = "- \(session.target.title)：\(describe(session.state))"
            if session.id == focused { line += String(localized: "［当前焦点］") }
            if let error = session.lastError { line += String(localized: " 最近错误：\(error)") }
            lines.append(line)
        }
        if workspace.allSessions.isEmpty { lines.append(String(localized: "（没有）")) }

        lines.append(browser.stateSummary)
        lines.append(tailscaleSummary)
        lines.append(String(localized: "密钥：\(keys.isEmpty ? "（没有）" : keys.map(\.name).joined(separator: "、"))"))
        let defaults = UserDefaults.standard
        lines.append(String(localized: "外观：深色主题=\(defaults.string(forKey: AppearanceKey.darkTheme) ?? TerminalTheme.claudeDark.id) 浅色主题=\(defaults.string(forKey: AppearanceKey.lightTheme) ?? TerminalTheme.claudeLight.id) 跟随系统=\(defaults.object(forKey: AppearanceKey.followSystem) as? Bool ?? true) 字号=\(Int(defaults.object(forKey: AppearanceKey.fontSize) as? Double ?? defaultFontSize))"))
        return lines.joined(separator: "\n")
    }

    /// The built-in Tailscale node and the tailnet's machines, for get_app_state.
    private var tailscaleSummary: String {
        let tailscale = Tailscale.shared
        guard tailscale.isEnabled else { return String(localized: "内置 Tailscale：未开启（设置 › Tailscale）") }
        switch tailscale.phase {
        case .running:
            var lines = [String(localized: "内置 Tailscale：已连接，本机 \(tailscale.selfName) \(tailscale.selfAddresses.joined(separator: " "))。连接下列设备（或 100.x 地址、MagicDNS 名称）的 SSH 会自动走它；Mosh 不支持。")]
            lines += tailscale.peers.map { "- \($0.shortName) \($0.addresses.joined(separator: " ")) \($0.os) \($0.online ? String(localized: "在线") : String(localized: "离线"))" }
            return lines.joined(separator: "\n")
        case .needsLogin: return String(localized: "内置 Tailscale：等待用户登录（设置 › Tailscale › 登录）")
        case .starting: return String(localized: "内置 Tailscale：正在启动")
        case .failed(let message): return String(localized: "内置 Tailscale：出错了：\(message)")
        case .off: return String(localized: "内置 Tailscale：已开启但没有运行")
        }
    }

    private func apply(_ input: JSONValue, to host: Host) throws {
        host.updatedAt = .now
        if let value = input["hostname"]?.string { host.hostname = value.trimmingCharacters(in: .whitespaces) }
        if let value = input["username"]?.string { host.username = value.trimmingCharacters(in: .whitespaces) }
        if let value = input["port"]?.int {
            guard (1...65535).contains(value) else { throw ToolError("端口号必须在 1–65535 之间") }
            host.port = value
        }
        if let value = input["name"]?.string { host.name = value }
        if let value = input["group"]?.string { host.group = value }
        if let value = input["protocol"]?.string.flatMap(ConnectionProtocol.init(rawValue:)) { host.connectionProtocol = value }
        if let value = input["color"]?.string.flatMap(HostTint.init(rawValue:)) { host.tint = value }
        if let keyName = input["key_name"]?.string {
            host.keyID = try key(named: keyName).id
            host.authMethod = .key
        }
        if let value = input["auth_method"]?.string.flatMap(AuthMethod.init(rawValue:)) {
            host.authMethod = value
            if value == .key, host.keyID == nil {
                guard let newest = keys.last else { throw ToolError("还没有任何密钥，先用 generate_key 生成一把") }
                host.keyID = newest.id
            }
        }
    }

    private func addServer(_ input: JSONValue) throws -> String {
        let host = Host()
        host.port = 22
        try apply(input, to: host)
        guard !host.hostname.isEmpty, !host.username.isEmpty else { throw ToolError("hostname 和 username 必填") }
        modelContext.insert(host)
        try? modelContext.save()
        return String(localized: "已添加 \(host.displayName)（id=\(host.id.uuidString)，\(host.subtitle)）")
    }

    private func updateServer(_ input: JSONValue) throws -> String {
        let host = try host(input)
        try apply(input, to: host)
        try? modelContext.save()
        return String(localized: "已更新 \(host.displayName)：\(host.subtitle)，协议 \(host.connectionProtocol.rawValue)，认证 \(host.authMethod.rawValue)")
    }

    private func deleteServer(_ input: JSONValue) async throws -> String {
        let host = try host(input)
        guard await confirm(ConfirmationRequest(title: String(localized: "删除服务器 \(host.displayName)？"), detail: host.subtitle, isDestructive: true)) else {
            return String(localized: "用户取消了删除")
        }
        sessions(for: host).forEach { $0.disconnect() }
        Keychain.delete(host.passwordAccount)
        modelContext.delete(host)
        try? modelContext.save()
        return String(localized: "已删除")
    }

    private func connect(_ input: JSONValue) async throws -> String {
        let host = try host(input)
        openHost(host)
        guard let session = workspace.selectedTab?.focusedPane else { return String(localized: "已打开终端") }
        for _ in 0..<40 {
            if session.hostKeyPrompt != nil { return String(localized: "正在等用户确认主机指纹（首次连接）。请提示用户核对后点“信任并连接”。") }
            switch session.state {
            case .connected: return String(localized: "已连接到 \(host.displayName)")
            case .needsPassword: return String(localized: "正在等用户在终端里输入密码（没有保存密码）。")
            case .failed(let message): return String(localized: "连接失败：\(message)")
            case .closed: return String(localized: "连接已关闭")
            default: try await Task.sleep(for: .milliseconds(500))
            }
        }
        return String(localized: "20 秒内还没连上，当前状态：\(describe(session.state))")
    }

    private func disconnect(_ input: JSONValue) throws -> String {
        let host = try host(input)
        let list = sessions(for: host)
        list.forEach { $0.disconnect() }
        return list.isEmpty ? String(localized: "这台服务器没有打开的会话") : String(localized: "已断开 \(list.count) 个会话")
    }

    private func diagnose(_ input: JSONValue) async throws -> String {
        let host = try host(input)
        let steps = await ConnectionDoctor.diagnose(ConnectionTarget(host: host))
        var report = ConnectionDoctor.report(steps)
        if let error = sessions(for: host).compactMap(\.lastError).last {
            report += String(localized: "\n终端里最近的错误：\(error)")
        }
        return report
    }

    private func runRemote(_ input: JSONValue) async throws -> String {
        let host = try host(input)
        guard let command = input["command"]?.string, !command.isEmpty else { throw ToolError("command 不能为空") }
        let reason = input["reason"]?.string ?? ""
        guard await confirm(ConfirmationRequest(
            title: String(localized: "在 \(host.displayName) 上执行命令？"),
            detail: reason,
            code: command,
            isDestructive: CommandRisk.isDangerous(command)
        )) else { return String(localized: "用户拒绝执行这条命令") }

        let result = try await ConnectionDoctor.run(ConnectionTarget(host: host), command: command)
        let output = result.output.count > 8000 ? String(localized: "…(前面省略)\n") + result.output.suffix(8000) : result.output
        return String(localized: "退出码 \(result.exitCode)\n\(output.isEmpty ? "（没有输出）" : output)")
    }

    private func targetSession(_ input: JSONValue) throws -> TerminalSession {
        if input["server"]?.string?.isEmpty == false {
            let host = try host(input)
            guard let session = sessions(for: host).last else { throw ToolError("\(host.displayName) 没有打开的终端") }
            return session
        }
        guard let session = workspace.selectedTab?.focusedPane else { throw ToolError("当前没有打开的终端") }
        return session
    }

    private func readTerminal(_ input: JSONValue) throws -> String {
        let session = try targetSession(input)
        let text = session.recentText(lines: min(max(input["lines"]?.int ?? 60, 5), 300))
        return String(localized: "【\(session.target.title) · \(describe(session.state))】\n\(text.isEmpty ? "（屏幕是空的）" : text)")
    }

    private func typeInTerminal(_ input: JSONValue) async throws -> String {
        let session = try targetSession(input)
        guard session.state == .connected else { throw ToolError("终端未连接：\(describe(session.state))") }
        guard let text = input["text"]?.string, !text.isEmpty else { throw ToolError("text 不能为空") }
        let enter = input["press_enter"]?.bool ?? false
        guard await confirm(ConfirmationRequest(
            title: String(localized: "在 \(session.target.title) 的终端里输入？"),
            detail: enter ? String(localized: "输入后会按回车执行") : String(localized: "只输入，不按回车"),
            code: text,
            isDestructive: enter && CommandRisk.isDangerous(text)
        )) else { return String(localized: "用户拒绝了") }
        session.sendText(text + (enter ? "\r" : ""))
        try await Task.sleep(for: .milliseconds(enter ? 1200 : 200))
        return String(localized: "已输入。终端现在显示：\n\(session.recentText(lines: 25))")
    }

    private func setAppearance(_ input: JSONValue) -> String {
        let defaults = UserDefaults.standard
        var changes: [String] = []
        let validTheme: (String?) -> String? = { id in id.flatMap { id in TerminalTheme.all.first { $0.id == id }?.id } }
        if let theme = validTheme(input["theme"]?.string) {
            defaults.set(theme, forKey: AppearanceKey.darkTheme)
            defaults.set(theme, forKey: AppearanceKey.lightTheme)
            defaults.set(false, forKey: AppearanceKey.followSystem)
            changes.append(String(localized: "主题=\(TerminalTheme.named(theme).name)"))
        }
        if let theme = validTheme(input["dark_theme"]?.string) {
            defaults.set(theme, forKey: AppearanceKey.darkTheme)
            changes.append(String(localized: "深色主题=\(TerminalTheme.named(theme).name)"))
        }
        if let theme = validTheme(input["light_theme"]?.string) {
            defaults.set(theme, forKey: AppearanceKey.lightTheme)
            changes.append(String(localized: "浅色主题=\(TerminalTheme.named(theme).name)"))
        }
        if let value = input["follow_system"]?.bool {
            defaults.set(value, forKey: AppearanceKey.followSystem)
            changes.append(String(localized: "跟随系统=\(value)"))
        }
        if let value = input["font"]?.string.flatMap(TerminalFont.init(rawValue:)) {
            defaults.set(value.rawValue, forKey: AppearanceKey.font)
            changes.append(String(localized: "字体=\(value.label)"))
        }
        if let value = input["font_size"]?.int {
            let size = Double(min(max(value, 9), 28))
            defaults.set(size, forKey: AppearanceKey.fontSize)
            changes.append(String(localized: "字号=\(Int(size))"))
        }
        if let value = input["cursor"]?.string.flatMap(CursorShape.init(rawValue:)) {
            defaults.set(value.rawValue, forKey: AppearanceKey.cursor)
            changes.append(String(localized: "光标=\(value.label)"))
        }
        if let value = input["cursor_blink"]?.bool {
            defaults.set(value, forKey: AppearanceKey.cursorBlink)
            changes.append(String(localized: "光标闪烁=\(value)"))
        }
        if case .number(let value)? = input["opacity"] {
            let opacity = min(max(value, 0.5), 1)
            defaults.set(opacity, forKey: AppearanceKey.opacity)
            changes.append(String(localized: "不透明度=\(Int(opacity * 100))%"))
        }
        return changes.isEmpty ? String(localized: "没有需要修改的项") : String(localized: "已修改：\(changes.joined(separator: "，"))")
    }

    private func generateKey(_ input: JSONValue) throws -> String {
        let key = try makeKey(named: input["name"]?.string ?? "Conch")
        return String(localized: "已生成密钥 \(key.name)。公钥：\n\(key.publicKey)")
    }

    private func makeKey(named name: String) throws -> SSHKey {
        let pair = KeyManager.generateEd25519(comment: name)
        let key = SSHKey(name: name, keyType: "ssh-ed25519", publicKey: pair.publicKey)
        try Keychain.set(pair.privateKey, for: key.privateKeyAccount)
        modelContext.insert(key)
        try? modelContext.save()
        return key
    }

    private func setupKeyLogin(_ input: JSONValue) async throws -> String {
        let host = try host(input)
        let key = try input["key_name"]?.string.map { try self.key(named: $0) } ?? makeKey(named: "Conch · \(host.displayName)")
        let publicLine = key.publicKey.split(separator: " ").prefix(2).joined(separator: " ")

        guard await confirm(ConfirmationRequest(
            title: String(localized: "为 \(host.displayName) 配置免密登录？"),
            detail: String(localized: "会把密钥“\(key.name)”的公钥追加到 \(host.username) 的 ~/.ssh/authorized_keys，验证成功后改用密钥登录。"),
            code: publicLine,
            isDestructive: false
        )) else { return String(localized: "用户取消了") }

        // Idempotent append with the permissions sshd insists on.
        let quoted = ShellQuoting.quote(publicLine + " " + key.name.replacingOccurrences(of: "'", with: ""))
        let command = "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys && (grep -qF '\(publicLine)' ~/.ssh/authorized_keys || echo \(quoted) >> ~/.ssh/authorized_keys) && echo CONCH_KEY_OK"
        let result = try await ConnectionDoctor.run(ConnectionTarget(host: host), command: command)
        guard result.output.contains("CONCH_KEY_OK") else {
            throw ToolError("写入公钥失败（退出码 \(result.exitCode)）：\(result.output.prefix(500))")
        }

        // Verify before switching, so a broken setup never locks the user out.
        var keyTarget = ConnectionTarget(host: host)
        keyTarget.authMethod = .key
        keyTarget.keyID = key.id
        do {
            _ = try await ConnectionDoctor.run(keyTarget, command: "true", timeout: 15)
        } catch {
            throw ToolError("公钥已写入，但用密钥登录测试失败：\(error.localizedDescription)。服务器可能禁用了公钥认证（PubkeyAuthentication），保持原认证方式不变。")
        }
        host.authMethod = .key
        host.keyID = key.id
        host.updatedAt = .now
        try? modelContext.save()
        return String(localized: "完成：\(host.displayName) 已改为用密钥“\(key.name)”免密登录，并验证通过。")
    }

    private func forgetHostKey(_ input: JSONValue) async throws -> String {
        let host = try host(input)
        let entry = KnownHosts.key(host: host.hostname, port: host.port)
        guard KnownHosts.all[entry] != nil else { return String(localized: "没有这台服务器的指纹记录") }
        guard await confirm(ConfirmationRequest(
            title: String(localized: "删除 \(host.displayName) 的主机指纹？"),
            detail: String(localized: "只有在确认服务器重装过系统时才应该这样做。下次连接会重新请你核对指纹。"),
            isDestructive: true
        )) else { return String(localized: "用户取消了") }
        KnownHosts.forget(entry)
        return String(localized: "已删除旧指纹，下次连接时会重新确认。")
    }
}

extension AgentToolbox {
    fileprivate func askCodingAgent(_ input: JSONValue) async throws -> String {
        let host = try host(input)
        let kind = AgentKind(rawValue: input["agent"]?.string ?? "") ?? .claude
        let directory = input["directory"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "~"
        guard let prompt = input["prompt"]?.string, !prompt.isEmpty else { throw ToolError("prompt 不能为空") }
        let hub = AgentHub.shared
        let connection = hub.connection(for: host)
        let conversation = AgentConversation(connection: connection, kind: kind, cwd: directory)
        guard await confirm(ConfirmationRequest(
            title: String(localized: "让 \(kind.label) 在 \(host.displayName) 上工作？"),
            detail: String(localized: "目录 \(directory)，权限模式“\(conversation.mode.label)”：\(conversation.mode.explanation)"),
            code: prompt,
            isDestructive: conversation.mode.isDangerous
        )) else { return String(localized: "用户取消了") }

        let started = hub.start(host: host, kind: kind, cwd: directory)
        started.send(prompt)
        hub.focusOnOpen = started.id
        openAgents()

        let deadline = Date.now.addingTimeInterval(TimeInterval(min(max(input["wait_seconds"]?.int ?? 120, 10), 600)))
        while started.isRunning, Date.now < deadline {
            try await Task.sleep(for: .seconds(1))
        }
        // Everything the agent said after our prompt.
        let replies = started.items.reversed().prefix { if case .user = $0.kind { false } else { true } }.reversed()
        let text = replies.compactMap { item -> String? in
            switch item.kind {
            case .text(let text): text
            case .tool(let tool): "［\(tool.title) \(tool.subject)］"
            case .notice(let text, let isError): isError ? String(localized: "错误：\(text)") : nil
            default: nil
            }
        }.joined(separator: "\n")
        var result = started.isRunning ? String(localized: "\(kind.label) 还在工作（已在“AI 编程”窗口打开，可以继续等或让用户去看）。目前进展：\n") : String(localized: "\(kind.label) 完成了：\n")
        result += text.isEmpty ? String(localized: "（还没有输出）") : text.clipped(to: 6000)
        if !started.deniedTools.isEmpty {
            result += String(localized: "\n它想使用 \(started.deniedTools.joined(separator: "、"))，但当前权限模式不允许；用户可以在“AI 编程”窗口里点“允许并继续”。")
        }
        return result
    }
}

struct ConfirmationRequest: Identifiable {
    let id = UUID()
    var title: String
    var detail: String
    var code: String?
    var isDestructive: Bool
}
