import SwiftUI
#if os(iOS)
import MapKit
#endif

/// Heartbeat settings, and on iPhone/iPad, staying connected in the background.
struct KeepAliveSettingsView: View {
    @AppStorage(KeepAliveSettings.intervalKey) private var interval = KeepAliveSettings.defaultInterval
    @AppStorage(KeepAliveSettings.countMaxKey) private var countMax = KeepAliveSettings.defaultCountMax
    #if os(iOS)
    @AppStorage(BackgroundKeepSettings.enabledKey) private var backgroundEnabled = false
    @AppStorage(BackgroundKeepSettings.minutesKey) private var minutes = BackgroundKeepSettings.defaultMinutes
    @AppStorage(BackgroundKeepSettings.recordLocationsKey) private var recordLocations = false
    @State private var keeper = BackgroundKeeper.shared
    @Environment(\.openURL) private var openURL
    #endif

    var body: some View {
        Form {
            Section {
                LabeledContent("心跳间隔") {
                    Stepper(value: $interval, in: 5...120, step: 5) {
                        Text("\(interval) 秒").monospacedDigit()
                    }
                }
                LabeledContent("断线判定") {
                    Stepper(value: $countMax, in: 1...10) {
                        Text("连续 \(countMax) 次无响应").monospacedDigit()
                    }
                }
            } header: {
                Text("心跳")
            } footer: {
                Text("每 \(interval) 秒向服务器发一次心跳，防止路由器、防火墙或 Tailscale 因为空闲断开连接；连续 \(countMax) 次（约 \(interval * countMax) 秒）没有回应就判定断线并自动重连。相当于 OpenSSH 的 ServerAliveInterval 和 ServerAliveCountMax。新设置对之后建立的连接生效。")
            }
            .conchCard()

            #if os(iOS)
            Section {
                Toggle("后台保持连接", isOn: $backgroundEnabled)
                    .onChange(of: backgroundEnabled) { keeper.settingsChanged() }
                if backgroundEnabled {
                    Picker("后台保持时长", selection: $minutes) {
                        ForEach(BackgroundKeepSettings.durations, id: \.self) { Text(BackgroundKeepSettings.label(minutes: $0)).tag($0) }
                    }
                    status
                }
            } header: {
                Text("后台")
            } footer: {
                Text("iOS 会在 App 离开屏幕约 30 秒后暂停它，连接随之中断。开启后，只要有连接在用，Conch 会用最低精度的定位保持在后台运行（状态栏会显示定位图标）。离开 Conch 超过设定时长、或所有连接都已断开时自动停止。")
            }
            .conchCard()

            Section {
                Toggle("记录连接地点", isOn: $recordLocations)
                    .onChange(of: recordLocations) { keeper.settingsChanged() }
                if recordLocations, keeper.authorization == .denied || keeper.authorization == .restricted {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        Label("没有定位权限，去设置里允许", systemImage: "location.slash")
                            .foregroundStyle(.orange)
                    }
                }
                if recordLocations || !keeper.records.isEmpty {
                    NavigationLink { ConnectionRecordsView() } label: {
                        LabeledContent("连接地点记录", value: String(localized: "\(keeper.records.count) 条"))
                    }
                }
            } header: {
                Text("连接地点")
            } footer: {
                Text("每次连上服务器时，记下时间和大致地点，方便回看在哪里、什么时候连过哪台服务器。只保存在本机，可随时清空。")
            }
            .conchCard()
            #endif
        }
        .conchGroupedBackground()
        .formStyle(.grouped)
        .navigationTitle("连接保活")
    }

    #if os(iOS)
    @ViewBuilder
    private var status: some View {
        switch keeper.authorization {
        case .denied, .restricted:
            VStack(alignment: .leading, spacing: 6) {
                Label("没有定位权限，后台保持连接和地点记录都无法使用", systemImage: "location.slash")
                    .foregroundStyle(.orange)
                Button("去设置里允许") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        case .notDetermined:
            Label("等待定位授权…", systemImage: "location")
                .foregroundStyle(.secondary)
        default:
            if keeper.isActive {
                Label(keeper.endsAt.map { String(localized: "正在保持连接，\($0.formatted(date: .omitted, time: .shortened)) 结束") } ?? String(localized: "正在保持连接"),
                      systemImage: "location.fill")
                    .foregroundStyle(.green)
            } else {
                Label("有连接时自动开始", systemImage: "location")
                    .foregroundStyle(.secondary)
            }
        }
    }
    #endif
}

#if os(iOS)
struct ConnectionRecordsView: View {
    @State private var keeper = BackgroundKeeper.shared
    @State private var confirmingClear = false

    private var located: [ConnectionRecord] {
        keeper.records.filter { $0.latitude != nil }
    }

    var body: some View {
        List {
            if !located.isEmpty {
                Section {
                    Map {
                        ForEach(located) { record in
                            Marker(record.title, systemImage: "apple.terminal",
                                   coordinate: CLLocationCoordinate2D(latitude: record.latitude ?? 0, longitude: record.longitude ?? 0))
                        }
                    }
                    .frame(height: 240)
                    .listRowInsets(EdgeInsets())
                }
                .conchCard()
            }
            Section {
                ForEach(keeper.records) { record in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(record.title).font(.body.weight(.medium))
                            Spacer()
                            Text(record.date, format: .dateTime.month().day().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Label(record.place ?? (record.latitude == nil ? String(localized: "位置未知") : String(localized: "正在查询地点…")), systemImage: "mappin.and.ellipse")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .conchCard()
        }
        .conchGroupedBackground()
        .overlay {
            if keeper.records.isEmpty {
                ContentUnavailableView("还没有记录", systemImage: "mappin.slash", description: Text("开启“记录连接地点”后，每次连上服务器都会记下时间和大致地点。"))
            }
        }
        .navigationTitle("连接地点记录")
        .toolbar {
            if !keeper.records.isEmpty {
                Button("清空", role: .destructive) { confirmingClear = true }
            }
        }
        .confirmationDialog("清空所有连接记录？", isPresented: $confirmingClear) {
            Button("清空", role: .destructive) { keeper.clearRecords() }
        }
    }
}
#endif
