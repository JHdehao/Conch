import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Settings › 共享文件夹: where the folder the user shares with the assistant is,
/// what's in it, and a way to open it in Files / Finder.
struct SharedFolderView: View {
    @State private var usage: Int64?
    @State private var itemCount = 0
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                LabeledContent("位置") {
                    #if os(iOS)
                    Text("“文件” › 我的 iPhone › Conch")
                    #else
                    Text("Conch 的文稿文件夹")
                    #endif
                }
                if let usage {
                    LabeledContent("内容", value: String(localized: "\(itemCount) 项 · \(ByteCountFormatter.string(fromByteCount: usage, countStyle: .file))"))
                }
                Button {
                    open()
                } label: {
                    #if os(iOS)
                    Label("在“文件”中打开", systemImage: "folder")
                    #else
                    Label("在访达中打开", systemImage: "folder")
                    #endif
                }
            } footer: {
                Text("你和 AI 助手共用这个文件夹：放进来的文件助手可以直接读、改、整理，助手做好的文件也存在这里。在微信等 App 里选“用其他应用打开” › Conch，文件会存进“收到的文件”，并直接出现在助手的输入框里。")
            }
            .conchCard()
            Section {
                NavigationLink { ServerFilesView() } label: {
                    Label("从服务器下载", systemImage: "arrow.down.circle")
                }
            } footer: {
                Text("浏览服务器上的文件并存进这个文件夹，走内置 Tailscale，不依赖系统 VPN。")
            }
            .conchCard()
        }
        .conchGroupedBackground()
        .formStyle(.grouped)
        .navigationTitle("共享文件夹")
        .task {
            let (size, count) = await Task.detached {
                (SharedFolder.diskUsage(), (try? FileManager.default.contentsOfDirectory(atPath: SharedFolder.url.path))?.filter { !$0.hasPrefix(".") }.count ?? 0)
            }.value
            usage = size
            itemCount = count
        }
    }

    private func open() {
        #if os(iOS)
        // Files opens straight at an app's folder through this scheme.
        if let url = URL(string: "shareddocuments://" + SharedFolder.url.path) { openURL(url) }
        #else
        NSWorkspace.shared.open(SharedFolder.url)
        #endif
    }
}
