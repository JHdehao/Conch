import SwiftUI

/// Interface and dictation languages, each either following the system or set
/// just for Conch.
struct LanguageSettingsView: View {
    /// Empty follows the system.
    @State private var interface = AppLanguage.override ?? ""
    @AppStorage(SpeechLanguage.key) private var speech = ""
    #if os(macOS)
    @State private var confirmingRelaunch = false
    #endif

    /// What the interface shows once Conch is reopened.
    private var nextInterface: String { interface.isEmpty ? AppLanguage.system : interface }

    var body: some View {
        Form {
            Section {
                Picker("界面语言", selection: interfaceBinding) {
                    LanguageLabel(title: String(localized: "跟随系统"), subtitle: AppLanguage.nativeName(AppLanguage.system))
                        .tag("")
                    ForEach(AppLanguage.available, id: \.self) { code in
                        LanguageLabel(title: AppLanguage.nativeName(code), subtitle: AppLanguage.localizedName(code))
                            .tag(code)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("界面语言")
            } footer: {
                if nextInterface == AppLanguage.current {
                    Text("只改变 Conch，不影响系统和其他 App。")
                }
            }
            .conchCard()

            if nextInterface != AppLanguage.current {
                Section {
                    relaunchNotice
                }
                .conchCard()
            }

            Section {
                speechPicker
            } header: {
                Text("语音输入")
            } footer: {
                #if os(iOS)
                Text("麦克风按钮按这个语言识别。说话时想临时换一种语言，长按麦克风就能切换。")
                #else
                Text("麦克风按钮按这个语言识别。说话时想临时换一种语言，右键点按麦克风就能切换。")
                #endif
            }
            .conchCard()
        }
        .conchGroupedBackground()
        .formStyle(.grouped)
        .navigationTitle("语言")
        .onChange(of: speech) { SpeechLanguage.remember(speech) }
    }

    private var interfaceBinding: Binding<String> {
        Binding {
            interface
        } set: { code in
            interface = code
            AppLanguage.override = code.isEmpty ? nil : code
        }
    }

    // MARK: - Relaunch

    @ViewBuilder
    private var relaunchNotice: some View {
        let name = AppLanguage.nativeName(nextInterface)
        #if os(iOS)
        Label {
            Text("在多任务界面关闭 Conch 再重新打开，界面就会切换为\(name)。")
        } icon: {
            Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
        }
        #else
        HStack {
            Label {
                Text("重新启动 Conch 后，界面会切换为\(name)。")
            } icon: {
                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
            }
            Spacer()
            Button("立即重新启动") { confirmingRelaunch = true }
        }
        .alert("重新启动 Conch？", isPresented: $confirmingRelaunch) {
            Button("重新启动") { AppLanguage.relaunch() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前打开的连接会断开。")
        }
        #endif
    }

    // MARK: - Speech

    @ViewBuilder
    private var speechPicker: some View {
        #if os(iOS)
        NavigationLink {
            SpeechLanguageList(selection: $speech)
        } label: {
            LabeledContent("识别语言", value: speechSummary)
        }
        #else
        Picker("识别语言", selection: $speech) {
            Text(followInterfaceTitle).tag("")
            Section("常用") {
                ForEach(SpeechLanguage.suggested, id: \.self) { Text(SpeechLanguage.displayName($0)).tag($0) }
            }
            .conchCard()
            Section("所有语言") {
                ForEach(SpeechLanguage.all.filter { !SpeechLanguage.suggested.contains($0) }, id: \.self) {
                    Text(SpeechLanguage.displayName($0)).tag($0)
                }
            }
            .conchCard()
        }
        #endif
    }

    private var speechSummary: String {
        speech.isEmpty ? String(localized: "跟随界面") : SpeechLanguage.displayName(speech)
    }

    private var followInterfaceTitle: String {
        guard let match = SpeechLanguage.followingInterface else { return String(localized: "跟随界面语言") }
        return String(localized: "跟随界面语言（\(SpeechLanguage.displayName(match))）")
    }
}

/// A language name with a smaller second line, e.g. its name in the other language.
private struct LanguageLabel: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let subtitle, subtitle != title {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A searchable list of every language the speech recognizer supports.
struct SpeechLanguageList: View {
    @Binding var selection: String
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private let suggested = SpeechLanguage.suggested
    private let all = SpeechLanguage.all

    var body: some View {
        List {
            if query.isEmpty {
                Section {
                    row("", title: String(localized: "跟随界面语言"),
                        subtitle: SpeechLanguage.followingInterface.map(SpeechLanguage.displayName))
                    ForEach(suggested, id: \.self) { row($0) }
                }
                .conchCard()
                Section("所有语言") {
                    ForEach(all.filter { !suggested.contains($0) }, id: \.self) { row($0) }
                }
                .conchCard()
            } else {
                ForEach(all.filter(matches), id: \.self) { row($0) }
            }
        }
        .conchGroupedBackground()
        #if os(iOS)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .navigationBarTitleDisplayMode(.inline)
        #else
        .searchable(text: $query)
        #endif
        .navigationTitle("识别语言")
    }

    private func row(_ id: String, title: String? = nil, subtitle: String? = nil) -> some View {
        Button {
            selection = id
            dismiss()
        } label: {
            HStack {
                LanguageLabel(title: title ?? SpeechLanguage.displayName(id), subtitle: subtitle ?? nativeName(id))
                Spacer()
                if selection == id {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The language's name in itself, e.g. "日本語（日本）", which helps find it.
    /// Chinese variants already have precise names, so they get none.
    private func nativeName(_ id: String) -> String? {
        guard !["zh", "yue", "wuu"].contains(Locale.Language(identifier: id).languageCode?.identifier ?? "") else { return nil }
        return Locale(identifier: id).localizedString(forIdentifier: id)
    }

    private func matches(_ id: String) -> Bool {
        let english = Locale(identifier: "en").localizedString(forIdentifier: id) ?? ""
        return [SpeechLanguage.displayName(id), nativeName(id) ?? "", english, id].contains { $0.localizedStandardContains(query) }
    }
}
