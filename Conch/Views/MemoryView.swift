import SwiftUI

/// What the assistant remembers across conversations; the user can review, edit or wipe it.
struct MemoryView: View {
    @State private var store = MemoryStore.shared
    @AppStorage(MemoryStore.enabledKey) private var enabled = true
    @State private var editing: MemoryEntry?
    @State private var adding = false
    @State private var confirmingClear = false

    var body: some View {
        Form {
            Section {
                Toggle("启用记忆", isOn: $enabled)
            } footer: {
                Text("开启后，助手会记住你的偏好、环境和纠正过它的做法，新对话里也能用上。你也可以直接对它说“记住……”或“忘掉……”。记忆只保存在本机，但每次对话都会作为上下文发给所选的 AI 服务；不会记密码和密钥。")
            }
            .conchCard()

            Section {
                ForEach(store.entries.reversed()) { entry in
                    Button { editing = entry } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.text).foregroundStyle(.primary)
                            Text(entry.updatedAt, format: .dateTime.year().month().day())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("编辑") { editing = entry }
                        Button("删除", role: .destructive) { try? store.forget(entry.id) }
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { try? store.forget(entry.id) }
                    }
                }
                Button { adding = true } label: { Label("添加一条", systemImage: "plus") }
            } header: {
                Text("已记住 \(store.entries.count) 条")
            }
            .conchCard()

            if !store.entries.isEmpty {
                Section {
                    Button("清空全部记忆", role: .destructive) { confirmingClear = true }
                }
                .conchCard()
            }
        }
        .conchGroupedBackground()
        .formStyle(.grouped)
        .navigationTitle("助手记忆")
        .confirmationDialog("清空助手的全部记忆？", isPresented: $confirmingClear) {
            Button("清空", role: .destructive) { store.clear() }
        }
        .sheet(item: $editing) { entry in
            MemoryEditor(title: String(localized: "编辑记忆"), text: entry.text) { text in
                try? store.remember(text, replacing: entry.id)
            }
        }
        .sheet(isPresented: $adding) {
            MemoryEditor(title: String(localized: "添加记忆"), text: "") { text in
                try? store.remember(text)
            }
        }
    }
}

private struct MemoryEditor: View {
    let title: String
    @State var text: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如：我的项目都放在 ~/code 下", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                }
                .conchCard()
            }
            .conchGroupedBackground()
            .formStyle(.grouped)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > MemoryStore.maxLength)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 220)
        #endif
    }
}
