import Foundation

/// Live status of a Linux server, read over the host's agent SSH connection: a POSIX
/// script prints /proc counters every 2 seconds and rates are worked out here, so
/// nothing is installed on the server.
@MainActor
@Observable
final class ServerMonitor {
    enum Phase: Equatable {
        case connecting
        case live
        case unsupported(String)
        case failed(String)
    }

    struct Sample: Identifiable {
        let id: Int
        let date: Date
        let value: Double
    }

    struct Partition: Identifiable {
        var id: String { mount }
        let mount: String
        let used: Int64
        let size: Int64
        var fraction: Double { size > 0 ? Double(used) / Double(size) : 0 }
    }

    struct Process: Identifiable {
        var id: Int { pid }
        let pid: Int
        let name: String
        var user: String
        /// Percent of one core, as `top` shows it.
        let cpu: Double
        let memory: Int64
    }

    /// Samples kept: 15 minutes at one every 2 seconds.
    static let historyLimit = 450

    let connection: AgentConnection
    private(set) var phase = Phase.connecting
    private(set) var hostname = ""
    private(set) var system = ""
    private(set) var kernel = ""
    private(set) var cores = 0
    private(set) var uptime: TimeInterval = 0
    private(set) var load: [Double] = []

    private(set) var cpu: Double = 0
    private(set) var cpuUser: Double = 0
    private(set) var cpuSystem: Double = 0
    private(set) var cpuIOWait: Double = 0
    private(set) var coreUsage: [Double] = []
    private(set) var memoryUsed: Int64 = 0
    private(set) var memoryTotal: Int64 = 0
    private(set) var swapUsed: Int64 = 0
    private(set) var swapTotal: Int64 = 0
    private(set) var partitions: [Partition] = []
    private(set) var networkInterface = ""
    private(set) var receiveRate: Double = 0
    private(set) var sendRate: Double = 0
    private(set) var readRate: Double = 0
    private(set) var writeRate: Double = 0
    private(set) var byCPU: [Process] = []
    private(set) var byMemory: [Process] = []

    private(set) var cpuHistory: [Sample] = []
    private(set) var receiveHistory: [Sample] = []
    private(set) var sendHistory: [Sample] = []

    var hasData: Bool { memoryTotal > 0 }
    var memoryFraction: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }
    /// The root partition, or the fullest one when there is no "/".
    var mainPartition: Partition? { partitions.first { $0.mount == "/" } ?? partitions.max { $0.fraction < $1.fraction } }

    @ObservationIgnored private var task: Task<Void, Never>?
    private let scratchID = UUID().uuidString.prefix(8).lowercased()
    @ObservationIgnored private var section = ""
    @ObservationIgnored private var frame: [String: [String]] = [:]
    @ObservationIgnored private var clockTicks = 100.0
    @ObservationIgnored private var pageSize: Int64 = 4096
    @ObservationIgnored private var lastUptime: Double?
    @ObservationIgnored private var lastCPU: [String: [UInt64]] = [:]
    @ObservationIgnored private var lastNetwork: (rx: UInt64, tx: UInt64)?
    @ObservationIgnored private var lastDisk: (read: UInt64, write: UInt64)?
    @ObservationIgnored private var users: [Int: String] = [:]
    @ObservationIgnored private var sampleID = 0

    init(connection: AgentConnection) {
        self.connection = connection
    }

    // MARK: - Running

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.connection.stream(self.script) { line, _ in self.handle(line) }
                } catch {
                    if Task.isCancelled { return }
                    self.phase = self.hasData ? .connecting : .failed(error.localizedDescription)
                    try? await Task.sleep(for: .seconds(3))
                }
                if case .unsupported = self.phase { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func retry() {
        stop()
        phase = .connecting
        start()
    }

    /// Sends SIGTERM; returns the error text when it didn't work.
    func terminate(_ process: Process) async -> String? {
        do {
            let output = try await connection.capture("kill \(process.pid) 2>&1 && echo @@OK", timeout: 15)
            if output.contains("@@OK") { return nil }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return error.localizedDescription
        }
    }

    /// Runs 15 frames and exits: Citadel doesn't close an exec channel when its reader
    /// goes away, so a bounded run is what stops the script once the page is closed.
    /// Per-process counters persist in a temp file between runs.
    private var script: String {
        #"""
        [ -r /proc/stat ] || { echo "@@UNSUPPORTED $(uname -s)"; exit 0; }
        D="${TMPDIR:-/tmp}"; T="$D/conch-mon-\#(scratchID)"
        find "$D" -maxdepth 1 -name 'conch-mon-*' -mmin +60 -exec rm -f {} + 2>/dev/null
        os=$(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")
        echo "@@INFO $(getconf CLK_TCK 2>/dev/null || echo 100) $(getconf PAGESIZE 2>/dev/null || echo 4096) $(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)|$(cat /proc/sys/kernel/hostname)|$(uname -r)|$os"
        i=0
        while [ $i -lt 15 ]; do
          i=$((i+1))
          echo @@F
          echo @@UP; cat /proc/uptime /proc/loadavg
          echo @@CPU; grep '^cpu' /proc/stat
          echo @@MEM; grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo
          echo @@NET; tail -n +3 /proc/net/dev
          echo @@DISK; awk '$3 ~ /^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|nvme[0-9]+n[0-9]+|mmcblk[0-9]+)$/ {print $3, $6, $10}' /proc/diskstats
          echo @@DF; df -P -k 2>/dev/null | tail -n +2
          awk '{ match($0, /\)[^)]*$/); c = RSTART; o = index($0, "("); split(substr($0, c + 2), f, " ");
                 print $1, f[12] + f[13], f[22], substr($0, o + 1, c - o - 1) }' /proc/[0-9]*/stat 2>/dev/null > "$T.cur"
          [ -f "$T.prev" ] || : > "$T.prev"
          awk 'FILENAME == ARGV[1] { p[$1] = $2; next } { print (($1 in p) ? $2 - p[$1] : 0), $0 }' "$T.prev" "$T.cur" > "$T.d"
          mv "$T.cur" "$T.prev"
          echo @@PS; sort -nr "$T.d" | head -n 12
          echo @@PM; sort -k4,4nr "$T.d" | head -n 12
          pids=$({ sort -nr "$T.d" | head -n 12; sort -k4,4nr "$T.d" | head -n 12; } | awk '{print $2}' | sort -u | paste -sd, -)
          echo @@PU; [ -n "$pids" ] && ps -o pid=,user= -p "$pids" 2>/dev/null
          echo @@END
          sleep 2
        done
        """#
    }

    // MARK: - Parsing

    private func handle(_ line: String) {
        if line.hasPrefix("@@UNSUPPORTED") {
            phase = .unsupported(String(line.dropFirst("@@UNSUPPORTED ".count)))
        } else if line.hasPrefix("@@INFO ") {
            readInfo(String(line.dropFirst("@@INFO ".count)))
        } else if line == "@@F" {
            frame = [:]
            section = ""
        } else if line == "@@END" {
            apply(frame)
            frame = [:]
        } else if line.hasPrefix("@@"), !line.contains(" ") {
            section = String(line.dropFirst(2))
        } else if !section.isEmpty {
            frame[section, default: []].append(line)
        }
    }

    private func readInfo(_ text: String) {
        let parts = text.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        let numbers = parts.first?.split(separator: " ").compactMap { Double($0) } ?? []
        if numbers.count >= 3 {
            clockTicks = max(numbers[0], 1)
            pageSize = Int64(numbers[1])
            cores = Int(numbers[2])
        }
        if parts.count > 1 { hostname = parts[1] }
        if parts.count > 2 { kernel = parts[2] }
        if parts.count > 3 { system = parts[3] }
    }

    private func apply(_ frame: [String: [String]]) {
        let now = Date()
        let up = frame["UP"] ?? []
        guard let newUptime = up.first?.split(separator: " ").first.flatMap({ Double($0) }) else { return }
        let interval = lastUptime.map { newUptime - $0 } ?? 0
        lastUptime = newUptime
        uptime = newUptime
        if up.count > 1 { load = up[1].split(separator: " ").prefix(3).compactMap { Double($0) } }

        readCPU(frame["CPU"] ?? [])
        readMemory(frame["MEM"] ?? [])
        readNetwork(frame["NET"] ?? [], interval: interval)
        readDisks(frame["DISK"] ?? [], interval: interval)
        partitions = Self.partitions(frame["DF"] ?? [])
        readProcesses(frame, interval: interval)

        sampleID += 1
        append(&cpuHistory, cpu, at: now)
        append(&receiveHistory, receiveRate, at: now)
        append(&sendHistory, sendRate, at: now)
        phase = .live
    }

    private func append(_ history: inout [Sample], _ value: Double, at date: Date) {
        history.append(Sample(id: sampleID, date: date, value: value))
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    }

    /// `cpu  user nice system idle iowait irq softirq steal …`, then one line per core.
    private func readCPU(_ lines: [String]) {
        var perCore: [Double] = []
        for line in lines {
            let fields = line.split(separator: " ")
            guard let name = fields.first.map(String.init) else { continue }
            let values = fields.dropFirst().prefix(8).compactMap { UInt64($0) }
            guard values.count >= 5 else { continue }
            defer { lastCPU[name] = values }
            guard let previous = lastCPU[name], previous.count == values.count else {
                if name != "cpu" { perCore.append(0) }
                continue
            }
            let delta = zip(values, previous).map { $0 >= $1 ? Double($0 - $1) : 0 }
            let total = delta.reduce(0, +)
            guard total > 0 else { if name != "cpu" { perCore.append(0) }; continue }
            let busy = (total - delta[3] - delta[4]) / total
            if name == "cpu" {
                cpu = busy
                cpuUser = (delta[0] + delta[1]) / total
                cpuSystem = (delta[2] + (delta.count > 6 ? delta[5] + delta[6] : 0)) / total
                cpuIOWait = delta[4] / total
            } else {
                perCore.append(busy)
            }
        }
        coreUsage = perCore
    }

    private func readMemory(_ lines: [String]) {
        var values: [String: Int64] = [:]
        for line in lines {
            let fields = line.split(separator: " ")
            if fields.count >= 2, let kb = Int64(fields[1]) { values[String(fields[0].dropLast())] = kb * 1024 }
        }
        memoryTotal = values["MemTotal"] ?? 0
        memoryUsed = memoryTotal - (values["MemAvailable"] ?? 0)
        swapTotal = values["SwapTotal"] ?? 0
        swapUsed = swapTotal - (values["SwapFree"] ?? 0)
    }

    /// Physical interfaces only: loopback, bridges, containers and tunnels would count
    /// the same traffic twice.
    private static let virtualInterfaces = ["lo", "veth", "docker", "br-", "virbr", "tailscale", "tun", "tap", "wg", "zt", "cni", "flannel", "vnet"]

    private func readNetwork(_ lines: [String], interval: Double) {
        var rx: UInt64 = 0, tx: UInt64 = 0, busiest: (name: String, bytes: UInt64) = ("", 0)
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard !Self.virtualInterfaces.contains(where: { name.hasPrefix($0) }) else { continue }
            let fields = parts[1].split(separator: " ").compactMap { UInt64($0) }
            guard fields.count >= 9 else { continue }
            rx += fields[0]
            tx += fields[8]
            if fields[0] + fields[8] >= busiest.bytes { busiest = (name, fields[0] + fields[8]) }
        }
        networkInterface = busiest.name
        if let last = lastNetwork, interval > 0 {
            receiveRate = rx >= last.rx ? Double(rx - last.rx) / interval : 0
            sendRate = tx >= last.tx ? Double(tx - last.tx) / interval : 0
        }
        lastNetwork = (rx, tx)
    }

    /// `name sectors-read sectors-written` per whole disk; a sector is 512 bytes here.
    private func readDisks(_ lines: [String], interval: Double) {
        var read: UInt64 = 0, written: UInt64 = 0
        for line in lines {
            let fields = line.split(separator: " ")
            guard fields.count == 3, let r = UInt64(fields[1]), let w = UInt64(fields[2]) else { continue }
            read += r
            written += w
        }
        if let last = lastDisk, interval > 0 {
            readRate = read >= last.read ? Double(read - last.read) * 512 / interval : 0
            writeRate = written >= last.write ? Double(written - last.write) * 512 / interval : 0
        }
        lastDisk = (read, written)
    }

    /// Real block devices from `df -P -k`; btrfs subvolumes and bind mounts show the
    /// same device again, so each device keeps only its shortest mount point.
    private static func partitions(_ lines: [String]) -> [Partition] {
        var byDevice: [String: Partition] = [:]
        for line in lines {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 6 else { continue }
            let device = String(fields[0])
            guard device.hasPrefix("/dev/"), !device.hasPrefix("/dev/loop"),
                  let size = Int64(fields[1]), let used = Int64(fields[2]), size > 0 else { continue }
            let mount = fields[5...].joined(separator: " ")
            guard !mount.hasPrefix("/snap"), !mount.hasPrefix("/var/lib/docker") else { continue }
            let partition = Partition(mount: mount, used: used * 1024, size: size * 1024)
            if let existing = byDevice[device], existing.mount.count <= mount.count { continue }
            byDevice[device] = partition
        }
        return byDevice.values.sorted { ($0.mount == "/" ? "" : $0.mount) < ($1.mount == "/" ? "" : $1.mount) }
    }

    /// `delta-ticks pid ticks rss-pages name` lines, top by CPU and top by memory.
    private func readProcesses(_ frame: [String: [String]], interval: Double) {
        for line in frame["PU"] ?? [] {
            let fields = line.split(separator: " ")
            if fields.count >= 2, let pid = Int(fields[0]) { users[pid] = String(fields[1]) }
        }
        func parse(_ lines: [String]) -> [Process] {
            lines.compactMap { line in
                let fields = line.split(separator: " ", maxSplits: 4)
                guard fields.count == 5, let delta = Double(fields[0]), let pid = Int(fields[1]),
                      let pages = Int64(fields[3]) else { return nil }
                let cpu = interval > 0 ? max(delta, 0) / (clockTicks * interval) * 100 : 0
                return Process(pid: pid, name: String(fields[4]), user: users[pid] ?? "", cpu: cpu, memory: pages * pageSize)
            }
        }
        byCPU = parse(frame["PS"] ?? [])
        byMemory = parse(frame["PM"] ?? [])
    }
}
