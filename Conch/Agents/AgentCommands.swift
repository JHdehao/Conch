import Foundation

/// The `/commands` each agent offers, and the ones Conch handles itself.
enum AgentCommands {
    /// Handled by Conch for both agents.
    static let local: [AgentSlashCommand] = [
        AgentSlashCommand(name: "resume", description: String(localized: "继续这个项目里之前的对话"), action: .local),
        AgentSlashCommand(name: "new", description: String(localized: "在同一个项目里开始新对话"), action: .local),
        AgentSlashCommand(name: "clear", description: String(localized: "开始新对话（同 /new）"), action: .local),
        AgentSlashCommand(name: "diff", description: String(localized: "查看项目里还没提交的改动"), action: .local),
        AgentSlashCommand(name: "status", description: String(localized: "查看当前对话的会话、模型、权限模式"), action: .local),
    ]

    /// Open Conch's picker; `/model 名称` and `/effort 级别` still work typed out.
    static let modelCommands: [AgentSlashCommand] = [
        AgentSlashCommand(name: "model", description: String(localized: "选择模型"), action: .local),
        AgentSlashCommand(name: "effort", description: String(localized: "选择思考强度"), action: .local),
    ]

    /// Chinese descriptions for Claude Code's common commands; anything else it
    /// reports (skills, custom commands) is listed with a generic label.
    private static let claudeDescriptions: [String: String] = [
        "compact": String(localized: "压缩对话上下文，腾出空间继续聊"),
        "context": String(localized: "查看上下文用了多少"),
        "usage": String(localized: "查看本次会话的花费和用量"),
        "cost": String(localized: "查看本次会话的花费和用量"),
        "model": String(localized: "选择模型"),
        "init": String(localized: "分析项目并生成 CLAUDE.md"),
        "review": String(localized: "审查代码改动"),
        "code-review": String(localized: "审查当前的代码改动"),
        "security-review": String(localized: "对当前改动做安全审查"),
        "simplify": String(localized: "检查改动里能简化、复用的地方并修改"),
        "debug": String(localized: "帮你排查一个问题"),
        "verify": String(localized: "验证改动是否真的生效"),
        "effort": String(localized: "选择思考强度"),
        "recap": String(localized: "总结这次对话"),
        "insights": String(localized: "分析使用情况"),
        "goal": String(localized: "设定一个持续追踪的目标"),
        "agents": String(localized: "查看可用的子代理"),
        "list-agents": String(localized: "列出正在运行的子代理"),
        "mcp": String(localized: "查看 MCP 服务器"),
        "rename": String(localized: "重命名这个会话"),
        "output-style": String(localized: "切换回复风格"),
        "batch": String(localized: "批量执行一组任务"),
        "loop": String(localized: "按间隔重复执行一个任务"),
        "schedule": String(localized: "创建定时任务"),
        "ultrareview": String(localized: "云端多代理深度审查（收费）"),
        "run": String(localized: "运行项目看改动效果"),
        "advisor": String(localized: "请更强的模型给建议"),
        "fast": String(localized: "切换快速模式"),
    ]

    /// Commands that only make sense in Claude Code's interactive terminal UI.
    private static let claudeHidden: Set<String> = ["config", "heapdump", "color", "focus", "doctor", "reload-plugins",
                                                    "exit", "quit", "vim", "terminal-setup", "theme", "login", "logout"]

    /// Most-used first; the rest keep Claude Code's own order.
    private static let claudePriority = ["compact", "context", "usage", "model", "init", "review", "code-review",
                                         "security-review", "simplify", "debug", "verify", "recap", "effort", "cost"]

    static func claude(names: [String], skills: [String]) -> [AgentSlashCommand] {
        let skillSet = Set(skills)
        let visible = names.filter { !claudeHidden.contains($0) && !$0.hasPrefix("__") && !["clear", "new", "status", "diff", "resume"].contains($0) }
        let ranked = claudePriority.filter(visible.contains)
            + visible.filter { !claudePriority.contains($0) && !skillSet.contains($0) }
            + visible.filter { !claudePriority.contains($0) && skillSet.contains($0) }
        let remote = ranked
            .filter { !["model", "effort"].contains($0) }
            .map { name in
                AgentSlashCommand(name: name, description: claudeDescriptions[name] ?? (skillSet.contains(name) ? String(localized: "技能") : String(localized: "命令")),
                                  takesArguments: skillSet.contains(name))
            }
        // /model is the most used, so it leads.
        return modelCommands + local + remote
    }

    /// Before Claude Code has reported its own list on this computer.
    static let claudeFallback = claude(names: ["compact", "context", "usage", "model", "init", "security-review", "recap"], skills: [])

    static let codexBuiltins: [AgentSlashCommand] = [
        AgentSlashCommand(name: "review", description: String(localized: "让 Codex 审查还没提交的改动；可附说明，如 /review 重点看并发"), takesArguments: true),
        AgentSlashCommand(name: "init", description: String(localized: "分析项目并生成 AGENTS.md")),
        AgentSlashCommand(name: "compact", description: String(localized: "压缩对话上下文，腾出空间继续聊"), action: .local),
    ]

    static func codex(prompts: [(name: String, description: String, path: String)]) -> [AgentSlashCommand] {
        modelCommands + local + codexBuiltins + prompts.map {
            AgentSlashCommand(name: "prompts:\($0.name)", description: $0.description.isEmpty ? String(localized: "自定义提示词") : $0.description,
                              action: .codexPrompt(path: $0.path), takesArguments: true)
        }
    }

    /// What `/init` asks Codex to do (its interactive UI has this built in).
    static let codexInitPrompt = """
    Create an AGENTS.md file at the root of this repository that serves as a guide for AI coding agents working here. \
    Explore the repository first, then cover: what the project does, how the code is laid out, the exact commands to \
    build, run, test and lint, coding conventions to follow, and any gotchas. Keep it concise and specific to this repo. \
    If an AGENTS.md already exists, improve it instead of replacing useful content.
    """

    /// Fills a Codex custom prompt's placeholders: $ARGUMENTS, $1…$9, and drops YAML front matter.
    static func expandCodexPrompt(_ template: String, arguments: String) -> String {
        var body = template
        if body.hasPrefix("---"), let end = body.range(of: "\n---", range: body.index(body.startIndex, offsetBy: 3)..<body.endIndex) {
            body = String(body[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let positional = arguments.split(separator: " ").map(String.init)
        body = body.replacingOccurrences(of: "$ARGUMENTS", with: arguments)
        for index in stride(from: 9, through: 1, by: -1) {
            body = body.replacingOccurrences(of: "$\(index)", with: index <= positional.count ? positional[index - 1] : "")
        }
        return body
    }
}

extension AgentScripts {
    /// Starts Claude Code just long enough to read its startup event (the command
    /// list); local commands don't call the API and nothing is saved to history.
    static func claudeCommands(cwd: String) -> String {
        """
        cd \(path(cwd)) 2>/dev/null
        claude -p --output-format stream-json --verbose --no-session-persistence -- /usage </dev/null 2>/dev/null | head -n 1
        """
    }

    static let codexPrompts = """
    for f in "$HOME"/.codex/prompts/*.md; do
      [ -f "$f" ] || continue
      printf '%s\\t%s\\t%s\\n' "$(basename "$f" .md)" "$(grep -m 1 '^description:' "$f" | cut -d: -f2- | sed 's/^ *//')" "$f"
    done
    """

    /// Codex's model list (from its cache of the service's models) and the
    /// model settings in config.toml. Only model lines are read from the config.
    static let codexModels = """
    f="$HOME/.codex/models_cache.json"
    if [ -f "$f" ] && command -v python3 >/dev/null 2>&1; then
    python3 - "$f" <<'PY'
    import json, sys
    try:
        models = json.load(open(sys.argv[1])).get("models", [])
    except Exception:
        sys.exit(0)
    clean = lambda s: (s or "").replace("\\t", " ").replace("\\n", " ")
    for m in models:
        if m.get("visibility") != "list":
            continue
        levels = ",".join(l.get("effort", "") for l in m.get("supported_reasoning_levels") or [])
        print("\\t".join(["@@MODEL", clean(m.get("slug")), clean(m.get("display_name")), clean(m.get("description")), levels]))
    PY
    fi
    grep -E '^[[:space:]]*model(_reasoning_effort)?[[:space:]]*=' "$HOME/.codex/config.toml" 2>/dev/null | head -n 2 | sed 's/^/@@CONFIG	/'
    """

    static func readFile(_ file: String) -> String {
        "cat \(ShellQuoting.quote(file))"
    }

    static func gitDiff(cwd: String) -> String {
        """
        cd \(path(cwd)) || exit 1
        git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "@@NOTGIT"; exit 0; }
        echo "@@STAT"
        git status --short | head -n 60
        echo "@@DIFF"
        git diff HEAD --no-color 2>/dev/null | head -n 1500
        """
    }
}
