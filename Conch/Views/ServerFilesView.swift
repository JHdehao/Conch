import Citadel
import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Settings › 共享文件夹 › 从服务器下载: browse a server over SFTP and save files into the
/// shared folder, where Files and other apps (SideStore…) can pick them up. It uses the
/// saved password or key and Conch's own Tailscale, so it still works when nothing else
/// on the phone can reach the server (Files' SMB goes through the system VPN instead).
struct ServerFilesView: View {
    @Query(sort: \Host.name) private var hosts: [Host]

    var body: some View {
        Form {
            if hosts.isEmpty {
                ContentUnavailableView("还没有服务器", systemImage: "server.rack", description: Text("先在“服务器”里添加一台。"))
            } else {
                Section {
                    ForEach(hosts) { host in
                        NavigationLink {
                            RemoteBrowser(host: host)
                        } label: {
                            HostRow(host: host, isConnected: false, showsInfo: false, onEdit: {})
                        }
                    }
                } footer: {
                    Text("用已保存的密码或密钥通过 SFTP 连接，Tailnet 里的服务器走内置 Tailscale。点文件就下载到共享文件夹的“服务器下载”里，同名文件会被替换。")
                }
                .conchCard()
            }
        }
        .conchGroupedBackground()
        .formStyle(.grouped)
        .navigationTitle("从服务器下载")
    }
}

/// One SFTP connection shared by every folder of a browse, plus the downloads started from it.
@MainActor @Observable
final class RemoteFileSession {
    struct Entry: Identifiable, Hashable {
        var id: String { path }
        let name: String
        let path: String
        let isFolder: Bool
        let isLink: Bool
        let size: Int64?
        let modified: Date?
    }

    struct Download {
        enum Phase { case running, done(URL), failed(String) }
        var phase: Phase = .running
        var received: Int64 = 0
        let total: Int64?

        var isRunning: Bool { if case .running = phase { true } else { false } }
    }

    let target: ConnectionTarget
    /// By remote path.
    var downloads: [String: Download] = [:]
    @ObservationIgnored nonisolated(unsafe) private var client: SSHClient?
    @ObservationIgnored private var sftp: SFTPClient?
    @ObservationIgnored private var connecting: Task<SFTPClient, Error>?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    /// Where downloads go: a folder of their own in the shared folder.
    static var folder: URL {
        SharedFolder.url.appending(path: String(localized: "服务器下载"), directoryHint: .isDirectory)
    }

    init(host: Host) {
        target = ConnectionTarget(host: host)
    }

    deinit {
        let client = client
        Task { try? await client?.close() }
    }

    // MARK: Connection

    private func open() async throws -> SFTPClient {
        if let sftp, sftp.isActive { return sftp }
        let stale = client
        client = nil
        sftp = nil
        Task { try? await stale?.close() }
        let password = target.authMethod == .password ? Keychain.string(for: target.passwordAccount) : nil
        // No one to ask about an unknown host key here; the terminal is where it gets trusted.
        let connection = try await SSHConnector.connect(target: target, password: password,
                                                        prompts: TransportPrompts(confirmHostKey: { _, _ in false }))
        client = connection.client
        let opened = try await connection.client.openSFTP()
        sftp = opened
        return opened
    }

    private func connected() async throws -> SFTPClient {
        if let sftp, sftp.isActive { return sftp }
        if let connecting { return try await connecting.value }
        let task = Task { try await self.open() }
        connecting = task
        defer { connecting = nil }
        return try await task.value
    }

    /// Runs `body` on the connection, reconnecting once if the old one had gone away.
    private func run<T>(_ body: (SFTPClient) async throws -> T) async throws -> T {
        let sftp = try await connected()
        do {
            return try await body(sftp)
        } catch {
            if sftp.isActive || error is CancellationError { throw error }
            return try await body(try await connected())
        }
    }

    // MARK: Listing

    private static func fileType(_ permissions: UInt32?) -> UInt32 { (permissions ?? 0) & 0o170000 }

    /// The folder's absolute path and contents: folders first, links followed. nil = home.
    func list(_ path: String?) async throws -> (path: String, entries: [Entry]) {
        try await run { sftp in
            let absolute = try await sftp.getRealPath(atPath: path ?? ".")
            var entries: [Entry] = []
            for item in try await sftp.listDirectory(atPath: absolute).flatMap(\.components)
            where item.filename != "." && item.filename != ".." {
                let full = absolute.hasSuffix("/") ? absolute + item.filename : absolute + "/" + item.filename
                let isLink = Self.fileType(item.attributes.permissions) == 0o120000
                var attributes = item.attributes
                if isLink, let resolved = try? await sftp.getAttributes(at: full) { attributes = resolved }
                entries.append(Entry(
                    name: item.filename,
                    path: full,
                    isFolder: Self.fileType(attributes.permissions) == 0o040000,
                    isLink: isLink,
                    size: attributes.size.map { Int64($0) },
                    modified: attributes.accessModificationTime?.modificationTime
                ))
            }
            entries.sort {
                if $0.isFolder != $1.isFolder { return $0.isFolder }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return (absolute, entries)
        }
    }

    // MARK: Downloads

    func download(_ entry: Entry) {
        guard downloads[entry.path]?.isRunning != true else { return }
        downloads[entry.path] = Download(total: entry.size)
        let destination = Self.folder.appending(path: AttachmentStore.safeName(entry.name))
        tasks[entry.path] = Task {
            do {
                _ = try await run { sftp in
                    try await AgentToolbox.download(entry.path, to: destination, over: sftp) { [weak self] bytes in
                        self?.downloads[entry.path]?.received = bytes
                    }
                }
                downloads[entry.path]?.phase = .done(destination)
            } catch is CancellationError {
                downloads[entry.path] = nil
            } catch {
                downloads[entry.path]?.phase = .failed(Self.message(for: error))
            }
            tasks[entry.path] = nil
        }
    }

    func cancel(_ entry: Entry) {
        tasks[entry.path]?.cancel()
    }

    static func message(for error: Error) -> String {
        if let transport = error as? TransportError, case .hostKeyRejected = transport {
            return String(localized: "还没有信任这台服务器的主机密钥：先在终端里连一次，信任后再来。")
        }
        return error.localizedDescription
    }

    static func openFolder(_ openURL: OpenURLAction) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #if os(iOS)
        // Files opens straight at a folder through this scheme.
        if let url = URL(string: "shareddocuments://" + folder.path) { openURL(url) }
        #else
        NSWorkspace.shared.open(folder)
        #endif
    }
}

/// One server's files, starting at the home folder.
private struct RemoteBrowser: View {
    @State private var session: RemoteFileSession

    init(host: Host) {
        _session = State(initialValue: RemoteFileSession(host: host))
    }

    var body: some View {
        RemoteFolderView(session: session, path: nil)
    }
}

private struct RemoteFolderView: View {
    let session: RemoteFileSession
    /// nil = the home folder.
    let path: String?
    @State private var absolute: String?
    @State private var entries: [RemoteFileSession.Entry]?
    @State private var error: String?
    @AppStorage("serverFiles.showHidden") private var showHidden = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            if let error {
                ContentUnavailableView {
                    Label("打不开", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试") { Task { await load() } }
                }
            } else if let entries {
                let shown = showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
                Section {
                    if shown.isEmpty {
                        Text("空文件夹").foregroundStyle(.secondary)
                    }
                    ForEach(shown) { entry in
                        if entry.isFolder {
                            NavigationLink {
                                RemoteFolderView(session: session, path: entry.path)
                            } label: {
                                Label(entry.name, systemImage: entry.isLink ? "folder.badge.gearshape" : "folder")
                            }
                        } else {
                            RemoteFileRow(
                                entry: entry,
                                download: session.downloads[entry.path],
                                start: { session.download(entry) },
                                cancel: { session.cancel(entry) }
                            )
                        }
                    }
                } header: {
                    if let absolute { Text(verbatim: absolute).textCase(nil) }
                }
                .conchCard()
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .conchGroupedBackground()
        .navigationTitle(path.map { ($0 as NSString).lastPathComponent } ?? session.target.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle("显示隐藏文件", isOn: $showHidden)
                    Button {
                        RemoteFileSession.openFolder(openURL)
                    } label: {
                        #if os(iOS)
                        Label("在“文件”中打开下载文件夹", systemImage: "folder")
                        #else
                        Label("在访达中打开下载文件夹", systemImage: "folder")
                        #endif
                    }
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
            }
        }
        .task { if entries == nil { await load() } }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            let listing = try await session.list(path)
            absolute = listing.path
            entries = listing.entries
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = RemoteFileSession.message(for: error)
        }
    }
}

private struct RemoteFileRow: View {
    let entry: RemoteFileSession.Entry
    let download: RemoteFileSession.Download?
    let start: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if download?.isRunning != true { start() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc")
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        detail
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing
        }
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    @ViewBuilder
    private var detail: some View {
        switch download?.phase {
        case .running:
            if let total = download?.total, total > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: Double(min(download?.received ?? 0, total)), total: Double(total))
                    Text(verbatim: "\(bytes(download?.received ?? 0)) / \(bytes(total))")
                }
            } else {
                Text(verbatim: bytes(download?.received ?? 0))
            }
        case .done:
            Text("已存到共享文件夹 › 服务器下载")
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        case nil:
            Text(verbatim: [entry.size.map(bytes), entry.modified?.formatted(date: .abbreviated, time: .shortened)]
                .compactMap { $0 }.joined(separator: " · "))
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch download?.phase {
        case .running:
            Button(action: cancel) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("取消下载")
        case .done(let url):
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .help("分享或用其他 App 打开")
        case .failed, nil:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
        }
    }
}
