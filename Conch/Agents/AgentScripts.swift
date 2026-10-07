import Foundation

/// Shell scripts Conch runs on the remote machine to drive Claude Code / Codex.
/// Everything is POSIX sh and works on macOS and Linux.
enum AgentScripts {
    /// Non-interactive SSH sessions skip .zshrc/.bashrc, where tools installed by
    /// npm, nvm, Homebrew or the Claude installer usually add themselves to PATH.
    /// These go after the user's own PATH so their choice of binary still wins.
    static let pathPrelude = """
    export PATH="$PATH:$HOME/.local/bin:$HOME/.claude/local:/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:$HOME/.bun/bin:$HOME/.volta/bin:$HOME/.cargo/bin"
    if ! command -v node >/dev/null 2>&1 && [ -s "$HOME/.nvm/nvm.sh" ]; then . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1; fi
    """

    /// Runs `script` under the user's login shell (so their profile's PATH applies),
    /// whatever that shell is — the script is passed base64-encoded so no quoting
    /// survives more than one layer.
    static func wrap(_ script: String) -> String {
        // sh reads the script from the pipe, so commands must not inherit it as stdin
        // (Node-based CLIs read stdin and would swallow the rest of the script).
        let body = pathPrelude + "\n{\n" + script + "\n} </dev/null\n"
        let encoded = Data(body.utf8).base64EncodedString()
        return "/bin/sh -c 'exec \"${SHELL:-/bin/sh}\" -lc \"printf %s \(encoded) | base64 -d | /bin/sh\"'"
    }

    /// A path for the shell: a leading `~` expands to $HOME, the rest is quoted.
    static func path(_ value: String) -> String {
        if value == "~" || value.isEmpty { return "\"$HOME\"" }
        if value.hasPrefix("~/") { return "\"$HOME\"/" + ShellQuoting.quote(String(value.dropFirst(2))) }
        return ShellQuoting.quote(value)
    }

    static let probe = """
    echo "@@HOME $HOME"
    for c in claude codex; do
      if command -v "$c" >/dev/null 2>&1; then
        echo "@@AGENT $c ok $("$c" --version 2>&1 | head -n 1)"
      else
        echo "@@AGENT $c"
      fi
    done
    """

    private static let mtime = #"m=$(date -r "$f" +%s 2>/dev/null || stat -c %Y "$f" 2>/dev/null)"#

    /// Cheap: just the newest session files and their modification times ("mtime\tpath").
    static func listSessionFiles(_ kind: AgentKind, limit: Int = 60) -> String {
        let glob = switch kind {
        case .claude: #""$HOME"/.claude/projects/*/*.jsonl"#
        case .codex: #""$HOME"/.codex/sessions/*/*/*/rollout-*.jsonl"#
        }
        return """
        ls -t \(glob) 2>/dev/null | head -n \(limit) | while IFS= read -r f; do
          \(mtime)
          printf '%s\\t%s\\n' "$m" "$f"
        done
        """
    }

    /// Titles and projects for just the given files (the ones not already cached).
    static func sessionDetails(_ kind: AgentKind, paths: [String]) -> String {
        let fields = switch kind {
        case .claude: """
              printf 'C\\t%s\\n' "$(grep -m 1 -o '"cwd":"[^"]*"' "$f")"
              printf 'T\\t%s\\n' "$(grep -o '"customTitle":"[^"]*"' "$f" | tail -n 1)"
              printf 'L\\t%s\\n' "$(grep -o '"lastPrompt":"[^"]\\{0,200\\}' "$f" | tail -n 1)"
              printf 'U\\t%s\\n' "$(grep -m 1 '"type":"user"' "$f" | grep -o -e '"content":"[^"]\\{0,200\\}' -e '"text":"[^"]\\{0,200\\}' | head -n 1)"
            """
        case .codex: """
              printf 'C\\t%s\\n' "$(head -n 1 "$f" | grep -o '"cwd":"[^"]*"' | head -n 1)"
              # First real user message: not the injected <environment_context>, the AGENTS.md
              # instructions Codex adds to every session, or another client's instructions.
              u=$(grep -o '"role":"user","content":\\[{"type":"input_text","text":"[^<"][^"]\\{0,200\\}' "$f" | grep -v -e '"text":"# AGENTS.md instructions' -e 'INSTRUCTIONS>' -e 'You have a way to give a user' | head -n 1 | sed 's/^.*"text":"/"text":"/')
              # The Codex app lists attached files first; the request follows "## My request:".
              case "$u" in *'# Files mentioned by the user'*)
                r=$(grep -m 1 -o '## My request:\\\\n[^"]\\{0,200\\}' "$f" | head -n 1)
                [ -n "$r" ] && u="\\"text\\":\\"${r#*:\\\\n}";;
              esac
              printf 'U\\t%s\\n' "$u"
            """
        }
        return """
        for f in \(paths.map(ShellQuoting.quote).joined(separator: " ")); do
          [ -f "$f" ] || continue
          \(mtime)
          printf '@@S\\t%s\\t%s\\n' "$m" "$f"
        \(fields)
        done
        """
    }

    static func history(_ session: AgentSessionSummary) -> String {
        let file = ShellQuoting.quote(session.path)
        // Screenshots and other images are stored inline as base64 (often twice per
        // tool call) and make up ~90% of a log: 24 MB → 1.5 MB without them. Any JSON
        // string of 250+ base64 characters becomes "", which keeps every line valid
        // JSON; nothing here shows images anyway. ({250} because BSD sed caps bounds at 255.)
        let stripImages = #"LC_ALL=C sed -E 's|"[A-Za-z0-9+/=]{250}[A-Za-z0-9+/=]*"|""|g'"#
        let select = switch session.kind {
        case .claude:
            #"LC_ALL=C grep -e '"type":"user"' -e '"type":"assistant"' \#(file) | tail -n 500 | "# + stripImages
        case .codex:
            #"LC_ALL=C grep -e '"type":"message"' -e '"type":"function_call' -e '"type":"custom_tool_call' \#(file) | grep -v '"role":"developer"' | tail -n 600 | "# + stripImages
        }
        // Gzipped when the machine has gzip (ungzip tells by the magic bytes).
        return select + #" | if command -v gzip >/dev/null 2>&1; then gzip -c; else cat; fi"#
    }

    /// Undoes the gzip `history` may apply; anything else comes back unchanged.
    static func ungzip(_ data: Data) throws -> Data {
        let bytes = [UInt8](data.prefix(10))
        guard bytes.count == 10, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return data }
        // gzip writing a pipe sets no optional header fields; the body is raw DEFLATE
        // (Apple's "zlib"), followed by an 8-byte CRC and length.
        guard bytes[3] == 0, data.count > 18 else { throw CocoaError(.fileReadCorruptFile) }
        let body = data.subdata(in: data.startIndex + 10 ..< data.endIndex - 8)
        return try (body as NSData).decompressed(using: .zlib) as Data
    }

    static func listDirectories(_ directory: String) -> String {
        """
        cd \(path(directory)) 2>/dev/null || { echo "@@NODIR"; cd; }
        echo "@@PWD $(pwd)"
        ls -1Ap 2>/dev/null | grep '/$' | head -n 400
        """
    }

    struct Run {
        var kind: AgentKind
        var cwd: String
        var prompt: String
        var sessionID: String?
        var mode: AgentMode
        var allowedTools: [String]
        var model: String?
        var effort: String?
        /// Claude only: emit a next-prompt suggestion after each turn (needs a recent Claude Code).
        var promptSuggestions = false
        /// Where this turn's attachments were uploaded (see AgentAttachmentPrompt).
        var uploadFolder: String?
        /// Remote paths of attached images: Codex gets them as localImage input.
        var imagePaths: [String] = []
        /// Claude only: a stream-json message file to read the prompt from, when it carries images.
        var messageFile: String?
        /// Lines written first to the agent's input pipe (`<runDir>/in`): Claude's message,
        /// the app server's handshake. More can be added while it works (`inject`); Claude
        /// Code and the Codex app server keep reading until the pipe closes.
        var opening: [String] = []
        /// Where the run lives on the computer: its log, pid files and input pipe. The
        /// agent runs detached and writes to the log, so a dropped connection doesn't end
        /// the turn; Conch reattaches and reads on from where it was (`attach`).
        var runDir = "~/.conch/runs/" + UUID().uuidString.lowercased()

        var inputPipe: String { runDir + "/in" }
    }

    /// Starts the agent in the background, reports its pid so Stop can kill it,
    /// and streams its JSON events on stdout.
    static func run(_ run: Run) -> String {
        var arguments: [String]
        switch run.kind {
        case .claude:
            let permission = switch run.mode {
            case .claudeAuto: "auto"
            case .claudeAcceptEdits: "acceptEdits"
            case .claudePlan: "plan"
            case .claudeBypass: "bypassPermissions"
            default: "default"
            }
            // stdio: questions and approvals come to Conch as control requests (AgentDecision).
            arguments = ["claude", "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                         "--permission-mode", permission, "--permission-prompt-tool", "stdio"]
            if let id = run.sessionID { arguments += ["--resume", id] }
            if let model = run.model, !model.isEmpty { arguments += ["--model", model] }
            if let effort = run.effort, !effort.isEmpty { arguments += ["--effort", effort] }
            // Lets Claude read the attachments (outside the project) without asking.
            if let folder = run.uploadFolder { arguments += ["--add-dir=" + folder] }
            if !run.allowedTools.isEmpty { arguments += ["--allowedTools"] + run.allowedTools }
            if run.promptSuggestions { arguments.append("--prompt-suggestions") }
            // Messages sent later come back as replays: the sign Claude has picked them up.
            arguments += ["--input-format", "stream-json", "--replay-user-messages"]
        case .codex:
            // Sandbox, approvals, model and effort go in the requests (CodexAppServerSession).
            arguments = ["codex", "app-server"]
        }
        let command = arguments.map(ShellQuoting.quote).joined(separator: " ")
        let dir = path(run.runDir)
        // Runs detached (nohup, no tie to this SSH channel). `hold` keeps a writer on the
        // pipe so the agent never sees EOF between messages; killing it (closeInput) lets
        // the agent finish and exit. The opening write runs in the background in case the
        // agent dies first. If Conch hasn't looked in (`seen`) and the agent has written
        // nothing for 10 minutes, its input is closed so it doesn't wait forever, unless
        // its last output is a question or approval still waiting for the user
        // (AgentDecision): that wait can last until the user comes back.
        let feed = run.messageFile.map { "cat \(ShellQuoting.quote($0))" }
            ?? "printf %s \(Data((run.opening.joined(separator: "\n") + "\n").utf8).base64EncodedString()) | base64 -d"
        // The app server logs to stderr; kept apart so it can't split a JSON line.
        // Claude's output goes through `claudeFilter` on the way to the log when the
        // computer's sed can flush per line (GNU -u, BSD -l); otherwise it's logged as is.
        let start = switch run.kind {
        case .codex:
            #"\#(command) <"$d/in" >>"$d/out" 2>"$d/err" &"#
        case .claude:
            """
            sink=""
            if sed -u -n p </dev/null >/dev/null 2>&1; then sink="sed -u"; elif sed -l -n p </dev/null >/dev/null 2>&1; then sink="sed -l"; fi
            if [ -n "$sink" ] && mkfifo -m 600 "$d/o"; then
              printf %s \(Data(claudeFilter.utf8).base64EncodedString()) | base64 -d > "$d/filter.sed"
              $sink -E -f "$d/filter.sed" <"$d/o" >>"$d/out" &
              filter=$!
              \(command) <"$d/in" >"$d/o" 2>&1 &
            else
              \(command) <"$d/in" >>"$d/out" 2>&1 &
            fi
            """
        }
        let launch = """
        mkfifo -m 600 "$d/in" || { echo 1 > "$d/exit"; exit 1; }
        filter=""
        \(start)
        pid=$!
        sleep 86400 >"$d/in" &
        hold=$!
        echo $hold > "$d/hold"
        { \(feed); } >"$d/in" &
        feeder=$!
        """
        let supervisor = """
        d=\(dir)
        cd \(path(run.cwd)) || { echo 1 > "$d/exit"; exit 1; }
        \(launch)
        echo $pid > "$d/pid"
        touch "$d/seen"
        ( while kill -0 $pid 2>/dev/null; do
            sleep 30
            if [ -z "$(find "$d/seen" -mmin -10 2>/dev/null)" ] && [ -z "$(find "$d/out" -mmin -10 2>/dev/null)" ] \\
              && ! tail -n 2 "$d/out" 2>/dev/null | grep -q -e '"control_request"' -e '/requestUserInput"' -e '/requestApproval"'; then
              kill $hold 2>/dev/null
            fi
          done ) &
        idle=$!
        wait $pid
        code=$?
        kill $hold $feeder $idle 2>/dev/null
        # Let the filter drain the pipe; a leftover child still holding it open mustn't keep this waiting.
        if [ -n "$filter" ]; then ( sleep 3; kill $filter 2>/dev/null ) & w=$!; wait $filter 2>/dev/null; kill $w 2>/dev/null; fi
        if [ $code -ne 0 ] && [ -s "$d/err" ]; then echo >> "$d/out"; tail -n 20 "$d/err" >> "$d/out"; fi
        rm -f "$d/in" "$d/o"
        echo $code > "$d/exit.tmp" && mv "$d/exit.tmp" "$d/exit"
        """

        return """
        cd \(path(run.cwd)) || { echo "@@ERROR 找不到目录 \(run.cwd.replacingOccurrences(of: "\"", with: ""))"; exit 1; }
        command -v \(run.kind.command) >/dev/null 2>&1 || { echo "@@MISSING"; exit 127; }
        # Runs nobody came back for (Conch was gone when they ended), after two days.
        mkdir -p "$HOME/.conch/runs" && chmod 700 "$HOME/.conch" "$HOME/.conch/runs"
        find "$HOME/.conch/runs" -mindepth 2 -maxdepth 2 -name out -mtime +2 2>/dev/null | while IFS= read -r o; do rm -rf "${o%/out}"; done
        d=\(dir)
        mkdir -p "$d" || { echo "@@ERROR 无法创建 $d"; exit 1; }
        : > "$d/out"
        printf %s \(Data(supervisor.utf8).base64EncodedString()) | base64 -d > "$d/run.sh"
        nohup /bin/sh "$d/run.sh" </dev/null >/dev/null 2>&1 &
        i=0
        while [ ! -s "$d/pid" ] && [ ! -f "$d/exit" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
        \(attach(runDir: run.runDir, offset: 0))
        """
    }

    /// What Claude Code writes that Conch never reads, cut before it crosses a slow link
    /// (about half of a turn's bytes): progress pings, thinking and tool-input deltas,
    /// block/message ends, the ids repeated on every text delta, and the tool list in init.
    /// Every line it keeps is still whole JSON. Lines are matched on Claude Code's key
    /// order; anything that doesn't match passes untouched.
    static let claudeFilter = #"""
    /^\{"type":"(rate_limit_event|system","subtype":"(thinking_tokens|status|task_summary|post_turn_summary))"/d
    /^\{"type":"stream_event","event":\{"type":"(content_block_stop|message_stop|message_delta)"/d
    /^\{"type":"stream_event","event":\{"type":"content_block_delta","index":[0-9]+,"delta":\{"type":"(thinking_delta|signature_delta|input_json_delta)"/d
    /^\{"type":"stream_event"/s/,"session_id":"[^"]*","parent_tool_use_id":[^,]*,"uuid":"[^"]*"\}$/}/
    /^\{"type":"system","subtype":"init"/s/,"tools":\[[^]]*\]//g

    """#

    /// Streams a run's log from byte `offset` until the agent exits, then `@@EXIT <code>`
    /// and the run's folder is removed. Used right after launching and to reattach after
    /// the connection dropped. `seen` tells the run someone is still watching; the
    /// `@@ALIVE` heartbeat makes sure a loop whose connection died doesn't keep saying so.
    static func attach(runDir: String, offset: Int) -> String {
        """
        d=\(path(runDir))
        [ -f "$d/out" ] || { echo "@@NORUN"; exit 0; }
        off=\(offset)
        [ -s "$d/pid" ] && echo "@@PID $(cat "$d/pid")"
        h=$(cat "$d/hold" 2>/dev/null)
        [ -n "$h" ] && kill -0 "$h" 2>/dev/null && echo "@@INPUT $h"
        n=0
        while :; do
          done=""
          [ -f "$d/exit" ] && done=1
          size=$(wc -c < "$d/out" | tr -d ' ')
          if [ "$size" -gt "$off" ]; then tail -c +$((off + 1)) "$d/out" | head -c $((size - off)); off=$size; fi
          [ -n "$done" ] && break
          n=$((n + 1))
          # Every 10 s: a line Conch ignores. When Conch is gone the write fails and this
          # loop ends, so `seen` goes stale and the run's idle rule can close its input.
          # Only between lines: never inside one the agent is still writing.
          if [ $((n % 20)) -eq 1 ] && { [ "$off" -eq 0 ] || [ -z "$(tail -c +$off "$d/out" | head -c 1)" ]; }; then
            echo "@@ALIVE" || exit 0
            touch "$d/seen"
          fi
          sleep 0.5
        done
        [ -n "$(tail -c 1 "$d/out")" ] && echo
        echo "@@EXIT $(cat "$d/exit")" && rm -rf "$d"
        """
    }

    /// Adds lines to a running agent's input pipe (see Run.inputPipe). Base64 so the
    /// JSON's quotes and newlines survive the shell; nothing is written once the agent is gone.
    static func inject(_ lines: [String], pipe: String, pid: Int32) -> String {
        let payload = Data(lines.map { $0 + "\n" }.joined().utf8).base64EncodedString()
        return """
        f=\(path(pipe))
        kill -0 \(pid) 2>/dev/null && [ -p "$f" ] || { echo "@@GONE"; exit 0; }
        printf %s \(payload) | base64 -d >"$f" && echo "@@SENT"
        """
    }

    /// Closes a run's input: the agent finishes what it has and exits.
    static func closeInput(holder: Int32) -> String {
        "kill \(holder) 2>/dev/null; true"
    }

    /// Ends the agent (and what it started); the run's folder goes too, since nobody
    /// will attach to read the rest.
    static func stop(pid: Int32, runDir: String? = nil) -> String {
        "pkill -TERM -P \(pid) 2>/dev/null; kill -TERM \(pid) 2>/dev/null; sleep 2; kill -KILL \(pid) 2>/dev/null; "
            + (runDir.map { "sleep 1; rm -rf \(path($0)); " } ?? "") + "true"
    }

    /// Reads one `"key":"value…"` fragment pulled out by grep -o, undoing JSON escapes.
    static func fragmentValue(_ fragment: Substring) -> String {
        guard let range = fragment.range(of: "\":\"") else { return "" }
        var raw = String(fragment[range.upperBound...])
        if raw.hasSuffix("\""), !raw.hasSuffix("\\\"") { raw.removeLast() }
        // grep may have cut the value mid-escape.
        for _ in 0..<6 {
            if let decoded = try? JSONDecoder().decode(String.self, from: Data("\"\(raw)\"".utf8)) {
                return decoded
            }
            guard !raw.isEmpty else { break }
            raw.removeLast()
        }
        return raw.replacingOccurrences(of: "\\n", with: " ")
    }

    static func parseSessions(_ output: String, kind: AgentKind) -> [AgentSessionSummary] {
        var sessions: [AgentSessionSummary] = []
        var current: AgentSessionSummary?
        var fallbackTitle = ""
        func flush() {
            guard var session = current else { return }
            if session.title.isEmpty { session.title = fallbackTitle }
            // The Codex app's file mentions: the title is what follows "## My request:".
            if let request = session.title.range(of: AgentAttachmentPrompt.codexRequestMarker) {
                session.title = String(session.title[request.upperBound...])
            }
            session.title = session.title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            // Kept even when untitled, so the cache remembers the file was already looked at.
            sessions.append(session)
            current = nil
            fallbackTitle = ""
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            switch fields.first {
            case "@@S" where fields.count == 3:
                flush()
                let path = String(fields[2])
                let file = (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
                let id = kind == .codex ? String(file.suffix(36)) : file
                let modified = Double(fields[1]).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
                current = AgentSessionSummary(id: id, kind: kind, title: "", cwd: "", modified: modified, path: path)
            case "C" where fields.count > 1:
                current?.cwd = fragmentValue(fields[1])
            case "T" where fields.count > 1:
                let title = fragmentValue(fields[1])
                if !title.isEmpty { current?.title = title }
            case "L" where fields.count > 1:
                let prompt = fragmentValue(fields[1])
                if current?.title.isEmpty == true, !prompt.isEmpty { current?.title = prompt }
            case "U" where fields.count > 1:
                fallbackTitle = fragmentValue(fields[1])
            default:
                continue
            }
        }
        flush()
        return sessions
    }
}
