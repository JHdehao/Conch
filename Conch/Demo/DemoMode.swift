#if DEBUG
import Foundation
import SwiftData

/// Screenshot demo (Debug builds only): launched with `-ConchDemo YES -ConchDemoScreen <screen>`,
/// Conch uses an in-memory database filled with made-up computers and conversations and
/// opens one screen. Nothing connects anywhere; every name, path and output below is invented.
enum DemoMode {
    static let isOn = UserDefaults.standard.bool(forKey: "ConchDemo")

    enum Screen: String {
        case home, agents, chat, approval, question, plan, codex, settings
    }

    static var screen: Screen {
        UserDefaults.standard.string(forKey: "ConchDemoScreen").flatMap(Screen.init(rawValue:)) ?? .home
    }

    /// Fills the database and the agent hub, and returns the conversation the screen shows.
    @MainActor
    static func seed(in context: ModelContext) -> AgentConversation? {
        let devbox = host("devbox", "devbox.local", "dev", .blue, context: context, minutesAgo: 2)
        let mac = host("mac-mini", "mac-mini.local", "me", .orange, context: context, minutesAgo: 40)
        let gpu = host("gpu-box", "gpu-box.lan", "ubuntu", .green, context: context, minutesAgo: 180)
        try? context.save()

        let hub = AgentHub.shared
        let chat = conversation(on: devbox, .claude, "~/code/ledger-api", history: Fixtures.rateLimit, model: "opus",
                                context: AgentContextUsage(used: 76_400, limit: 200_000), running: true)
        let approval = conversation(on: devbox, .claude, "~/code/web-dashboard", history: Fixtures.dependencies,
                                    live: Fixtures.pushApproval, model: "sonnet", mode: .claudeDefault,
                                    context: AgentContextUsage(used: 41_200, limit: 200_000), running: true)
        let question = conversation(on: mac, .claude, "~/Projects/pocket-notes", history: Fixtures.export,
                                    live: Fixtures.exportQuestion, model: "opus",
                                    context: AgentContextUsage(used: 23_800, limit: 200_000), running: true)
        let plan = conversation(on: gpu, .claude, "~/trainer", history: Fixtures.resume, live: Fixtures.resumePlan,
                                model: "opus", mode: .claudePlan,
                                context: AgentContextUsage(used: 58_100, limit: 200_000), running: true)
        let codex = conversation(on: gpu, .codex, "~/trainer", history: Fixtures.dataloader, model: "gpt-5.5",
                                 context: AgentContextUsage(used: 31_500, limit: 272_000), running: false)
        hub.addDemo([chat, approval, question, plan, codex])
        hub.seedDemoSessions(Fixtures.recent(devbox: devbox.id, mac: mac.id, gpu: gpu.id))

        return switch screen {
        case .chat: chat
        case .approval: approval
        case .question: question
        case .plan: plan
        case .codex: codex
        case .home, .agents, .settings: nil
        }
    }

    @MainActor
    private static func host(_ name: String, _ hostname: String, _ user: String, _ tint: HostTint,
                             context: ModelContext, minutesAgo: Double) -> Host {
        let host = Host(name: name, hostname: hostname, username: user)
        host.tint = tint
        host.lastConnectedAt = Date(timeIntervalSinceNow: -minutesAgo * 60)
        context.insert(host)
        return host
    }

    @MainActor
    private static func conversation(on host: Host, _ kind: AgentKind, _ cwd: String, history: [String], live: [String] = [],
                                      model: String, mode: AgentMode? = nil, context: AgentContextUsage, running: Bool) -> AgentConversation {
        let target = ConnectionTarget(host: host)
        AgentHub.shared.skipDemoCommands(hostID: target.hostID, kind: kind)
        let conversation = AgentConversation(connection: AgentConnection(target: target), kind: kind, cwd: cwd)
        if let mode { conversation.mode = mode }
        conversation.showDemo(history: history, live: live, model: model, context: context, running: running)
        return conversation
    }
}

/// Made-up agent output in the agents' own formats, read by the real parsers.
private enum Fixtures {
    static let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false

    static func t(_ zh: String, _ en: String) -> String { isChinese ? zh : en }

    // MARK: Claude Code

    static let rateLimit: [String] = [
        initLine("demo-rate-limit", cwd: "/home/dev/code/ledger-api", model: "opus"),
        user("u1", t("给登录接口加限流：同一个 IP 每分钟最多 10 次，超出返回 429，再补上测试。",
                     "Add rate limiting to the login endpoint: at most 10 attempts per IP per minute, 429 beyond that. Add tests too.")),
        assistant("a1", [text(t("先看看登录处理和现有的中间件。", "Let me look at the login handler and the existing middleware first.")),
                         tool("t1", "Grep", ["pattern": "func .*Login", "path": "/home/dev/code/ledger-api/internal"])]),
        result("t1", "internal/auth/handler.go:42:func (h *Handler) Login(w http.ResponseWriter, r *http.Request) {"),
        assistant("a2", [tool("t2", "Read", ["file_path": "/home/dev/code/ledger-api/internal/http/router.go"])]),
        result("t2", "func NewRouter(h *auth.Handler) chi.Router {\n\tr := chi.NewRouter()\n\tr.Use(middleware.RequestID, middleware.Logger)\n\tr.Post(\"/login\", h.Login)\n\tr.Post(\"/logout\", h.Logout)\n\treturn r\n}"),
        assistant("a3", [tool("t3", "TodoWrite", ["todos": [
            ["content": t("读懂登录流程", "Understand the login flow"), "status": "completed"],
            ["content": t("实现按 IP 计数的限流中间件", "Write a per-IP rate limit middleware"), "status": "completed"],
            ["content": t("只给 /login 挂上中间件", "Attach it to /login only"), "status": "completed"],
            ["content": t("补充单元测试", "Add unit tests"), "status": "in_progress"],
        ]])]),
        result("t3", "Todos updated"),
        assistant("a4", [tool("t4", "Edit", [
            "file_path": "/home/dev/code/ledger-api/internal/http/router.go",
            "old_string": "\tr.Post(\"/login\", h.Login)",
            "new_string": "\tr.With(RateLimit(10, time.Minute)).Post(\"/login\", h.Login)",
        ])]),
        result("t4", "The file has been updated."),
        assistant("a5", [tool("t5", "Bash", ["command": "go test ./internal/http/... -run RateLimit -v",
                                             "description": t("运行限流测试", "Run the rate limit tests")])]),
        result("t5", """
        === RUN   TestRateLimitAllowsTen
        --- PASS: TestRateLimitAllowsTen (0.00s)
        === RUN   TestRateLimitBlocksEleventh
        --- PASS: TestRateLimitBlocksEleventh (0.00s)
        === RUN   TestRateLimitResetsAfterWindow
        --- PASS: TestRateLimitResetsAfterWindow (0.01s)
        PASS
        ok  \texample.com/ledger-api/internal/http\t0.214s
        """),
        assistant("a6", [text(t("""
        限流测试全部通过。改动：

        - `internal/http/ratelimit.go`：按客户端 IP 计数的固定窗口，超出返回 **429** 并带上 `Retry-After`
        - `router.go`：只给 `/login` 挂上中间件，其他接口不受影响

        再跑一遍完整测试确认没有别的影响。
        """, """
        All rate limit tests pass. Changes:

        - `internal/http/ratelimit.go`: a fixed window counted per client IP; over the limit it answers **429** with `Retry-After`
        - `router.go`: the middleware wraps `/login` only, other routes are untouched

        Running the full suite to make sure nothing else broke.
        """)),
        tool("t6", "Bash", ["command": "go test ./...", "description": t("运行全部测试", "Run all tests")])]),
    ]

    static let dependencies: [String] = [
        initLine("demo-deps", cwd: "/home/dev/code/web-dashboard", model: "sonnet"),
        user("u1", t("把依赖升级到最新，修好构建，然后推送分支。", "Upgrade the dependencies, fix the build, then push the branch.")),
        assistant("a1", [tool("t1", "Bash", ["command": "npm outdated", "description": t("查看过期依赖", "List outdated packages")])]),
        result("t1", "Package      Current  Wanted  Latest\nvite           6.3.5   6.3.5   7.1.2\nvitest         3.2.4   3.2.4   4.0.1\nreact-router   7.6.0   7.9.1   7.9.1"),
        assistant("a2", [tool("t2", "Edit", [
            "file_path": "/home/dev/code/web-dashboard/package.json",
            "old_string": "    \"vite\": \"^6.3.5\",\n    \"vitest\": \"^3.2.4\"",
            "new_string": "    \"vite\": \"^7.1.2\",\n    \"vitest\": \"^4.0.1\"",
        ])]),
        result("t2", "The file has been updated."),
        assistant("a3", [tool("t3", "Bash", ["command": "npm install && npm run build",
                                             "description": t("安装并构建", "Install and build")])]),
        result("t3", "added 12 packages, changed 31 packages in 9s\n\n> web-dashboard@2.4.0 build\n> vite build\n\n✓ 412 modules transformed.\ndist/index.html   0.62 kB\ndist/assets/index.js  184.31 kB │ gzip: 58.02 kB\n✓ built in 2.81s"),
        assistant("a4", [text(t("构建通过，已提交到 `chore/deps-upgrade`。推送需要你确认：",
                                "The build passes and the changes are committed on `chore/deps-upgrade`. Pushing needs your OK:"))]),
    ]

    static let pushApproval: [String] = [
        ask("req-push", tool: "Bash", input: ["command": "git push -u origin chore/deps-upgrade",
                                              "description": t("推送分支到远程", "Push the branch to the remote")]),
    ]

    static let export: [String] = [
        initLine("demo-export", cwd: "/Users/me/Projects/pocket-notes", model: "opus"),
        user("u1", t("给笔记加一个导出功能。", "Add a way to export notes.")),
        assistant("a1", [tool("t1", "Glob", ["pattern": "Sources/**/Note*.swift"])]),
        result("t1", "Sources/Model/Note.swift\nSources/Model/NoteStore.swift\nSources/Views/NoteList.swift"),
        assistant("a2", [text(t("笔记存在 `NoteStore` 里，导出可以有几种做法，先确认两件事：",
                                "Notes live in `NoteStore`. There are a few ways to do this, so two quick questions first:"))]),
    ]

    static let exportQuestion: [String] = [
        ask("req-export", tool: "AskUserQuestion", input: ["questions": [
            ["question": t("导出成什么格式？", "Which formats should export support?"), "header": t("格式", "Format"), "multiSelect": true,
             "options": [
                ["label": "Markdown", "description": t("每条笔记一个 .md 文件，打包成 zip", "One .md file per note, zipped")],
                ["label": "PDF", "description": t("排好版的单个文件，适合分享", "A single formatted file, good for sharing")],
                ["label": "JSON", "description": t("完整数据，方便备份和迁移", "Full data, for backups and moving devices")],
             ]] as [String: Any],
            ["question": t("导出入口放在哪里？", "Where should export live?"), "header": t("入口", "Entry"), "multiSelect": false,
             "options": [
                ["label": t("笔记列表的分享按钮", "Share button on the list"), "description": t("可以多选笔记一起导出", "Export several notes at once")],
                ["label": t("设置页", "Settings"), "description": t("一次导出全部笔记", "Export everything in one go")],
             ]] as [String: Any],
        ]]),
    ]

    static let resume: [String] = [
        initLine("demo-resume", cwd: "/home/ubuntu/trainer", model: "opus"),
        user("u1", t("训练跑到一半崩了就得从头来。改成能从最近的检查点继续。",
                     "When training crashes halfway it starts over. Make it resume from the latest checkpoint.")),
        assistant("a1", [tool("t1", "Grep", ["pattern": "save_checkpoint|load_state_dict", "path": "/home/ubuntu/trainer/src"])]),
        result("t1", "src/train.py:88:    save_checkpoint(model, optimizer, step, path=cfg.ckpt_dir)\nsrc/utils/ckpt.py:12:def save_checkpoint(model, optimizer, step, path):"),
        assistant("a2", [tool("t2", "Read", ["file_path": "/home/ubuntu/trainer/src/utils/ckpt.py"])]),
        result("t2", "def save_checkpoint(model, optimizer, step, path):\n    torch.save({\"model\": model.state_dict(), \"step\": step}, f\"{path}/step_{step}.pt\")"),
    ]

    static let resumePlan: [String] = [
        ask("req-plan", tool: "ExitPlanMode", input: ["plan": t("""
        ## 断点续训

        1. **补全检查点内容**：`save_checkpoint` 目前只存模型权重，加上优化器、学习率调度器、随机数状态和数据进度
        2. **原子写入**：先写 `step_N.pt.tmp` 再重命名，崩溃时不会留下半个文件
        3. **启动时自动恢复**：`train.py` 启动先找 `ckpt_dir` 里最新的完整检查点，有就从那一步继续
        4. **只留最近 3 个**，避免占满磁盘
        5. **测试**：训练 20 步后杀掉进程，重启后从第 20 步继续，损失曲线前后一致
        """, """
        ## Resume training

        1. **Save everything**: `save_checkpoint` only keeps model weights; add the optimizer, LR scheduler, RNG state and data position
        2. **Atomic writes**: write `step_N.pt.tmp`, then rename, so a crash never leaves half a file
        3. **Resume on start**: `train.py` looks for the newest complete checkpoint in `ckpt_dir` and continues from that step
        4. **Keep the last 3** so the disk doesn't fill up
        5. **Test**: kill the run after 20 steps, restart, and check it continues at step 20 with a matching loss curve
        """)]),
    ]

    // MARK: Codex

    static let dataloader: [String] = [
        codexMessage("user", t("为什么 8 卡训练的吞吐还不如单卡？", "Why is 8-GPU training slower than a single GPU?")),
        codexCall("c1", "nvidia-smi --query-gpu=index,utilization.gpu --format=csv"),
        codexOutput("c1", "index, utilization.gpu [%]\n0, 23 %\n1, 19 %\n2, 21 %\n3, 18 %\n4, 22 %\n5, 20 %\n6, 17 %\n7, 19 %"),
        codexCall("c2", "rg -n \"num_workers|pin_memory\" src/"),
        codexOutput("c2", "src/data.py:31:    loader = DataLoader(ds, batch_size=cfg.batch, num_workers=0, pin_memory=False)"),
        codexMessage("assistant", t("""
        GPU 利用率只有 20% 左右，瓶颈在数据加载：`src/data.py` 里 `num_workers=0`，8 个进程都在主线程里解码图片。

        建议：
        1. `num_workers` 设为每卡 6～8，打开 `pin_memory` 和 `persistent_workers`
        2. 用 `DistributedSampler`，现在每张卡都在读完整数据集

        要我直接改吗？
        """, """
        GPU utilization sits around 20%, so the bottleneck is data loading: `src/data.py` uses `num_workers=0`, so all 8 processes decode images on their main thread.

        Suggested fix:
        1. Set `num_workers` to 6–8 per GPU and turn on `pin_memory` and `persistent_workers`
        2. Use a `DistributedSampler`; right now every GPU reads the whole dataset

        Want me to make the change?
        """)),
    ]

    // MARK: Past sessions

    static func recent(devbox: UUID, mac: UUID, gpu: UUID) -> [UUID: [AgentSessionSummary]] {
        func session(_ id: String, _ kind: AgentKind, _ title: String, _ cwd: String, hoursAgo: Double) -> AgentSessionSummary {
            AgentSessionSummary(id: id, kind: kind, title: title, cwd: cwd, modified: Date(timeIntervalSinceNow: -hoursAgo * 3600),
                                path: "/demo/\(id).jsonl")
        }
        return [
            devbox: [
                session("r1", .claude, t("修复账单导出的时区问题", "Fix time zones in the invoice export"), "/home/dev/code/ledger-api", hoursAgo: 3),
                session("r2", .codex, t("给 CI 加上缓存", "Cache dependencies in CI"), "/home/dev/code/web-dashboard", hoursAgo: 26),
            ],
            mac: [
                session("r3", .claude, t("深色模式下的图标对比度", "Icon contrast in dark mode"), "/Users/me/Projects/pocket-notes", hoursAgo: 7),
            ],
            gpu: [
                session("r4", .codex, t("评估脚本输出 JSON 报告", "JSON report from the eval script"), "/home/ubuntu/trainer", hoursAgo: 30),
            ],
        ]
    }

    // MARK: Line builders

    static func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }

    static func initLine(_ session: String, cwd: String, model: String) -> String {
        json(["type": "system", "subtype": "init", "session_id": session, "cwd": cwd, "model": model])
    }

    static func user(_ id: String, _ text: String) -> String {
        json(["type": "user", "uuid": id, "message": ["role": "user", "content": text]])
    }

    static func assistant(_ id: String, _ blocks: [[String: Any]]) -> String {
        json(["type": "assistant", "uuid": id, "message": ["id": id, "role": "assistant", "content": blocks] as [String: Any]])
    }

    static func text(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    static func tool(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": input]
    }

    static func result(_ id: String, _ output: String) -> String {
        json(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": output]]] as [String: Any]])
    }

    static func ask(_ requestID: String, tool: String, input: [String: Any]) -> String {
        json(["type": "control_request", "request_id": requestID,
              "request": ["subtype": "can_use_tool", "tool_name": tool, "input": input] as [String: Any]])
    }

    static func codexMessage(_ role: String, _ text: String) -> String {
        json(["type": "response_item", "payload": ["type": "message", "role": role,
                                                   "content": [["type": role == "user" ? "input_text" : "output_text", "text": text]]] as [String: Any]])
    }

    static func codexCall(_ id: String, _ command: String) -> String {
        json(["type": "response_item", "payload": ["type": "function_call", "name": "shell", "call_id": id,
                                                   "arguments": json(["command": ["bash", "-lc", command]])]])
    }

    static func codexOutput(_ id: String, _ output: String) -> String {
        json(["type": "response_item", "payload": ["type": "function_call_output", "call_id": id, "output": output]])
    }
}
#endif
