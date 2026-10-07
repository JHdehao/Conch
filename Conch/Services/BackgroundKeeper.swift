import Foundation

/// A past connection and roughly where it was made from.
struct ConnectionRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var hostname: String
    var date: Date
    var latitude: Double?
    var longitude: Double?
    var place: String?
}

enum BackgroundKeepSettings {
    static let enabledKey = "keepalive.background"
    static let minutesKey = "keepalive.backgroundMinutes"
    static let recordsKey = "keepalive.connectionRecords"
    static let recordLocationsKey = "keepalive.recordLocations"
    /// Choices for how long to stay alive in the background; 0 means no limit.
    static let durations = [5, 15, 30, 60, 120, 0]
    static let defaultMinutes = 30

    static var minutes: Int {
        UserDefaults.standard.object(forKey: minutesKey) as? Int ?? defaultMinutes
    }

    static func label(minutes: Int) -> String {
        switch minutes {
        case 0: String(localized: "不限时")
        case 60: String(localized: "1 小时")
        case 120: String(localized: "2 小时")
        default: String(localized: "\(minutes) 分钟")
        }
    }
}

#if os(iOS)
import CoreLocation
import UserNotifications

/// Keeps SSH sessions alive while Conch is in the background.
///
/// iOS suspends apps about 30 seconds after they leave the screen, which stops
/// heartbeats and lets servers and NATs drop the connection. An app that is
/// receiving location updates keeps running, so — only when the user has turned
/// this on and only while there are live connections — Conch runs low-accuracy
/// location updates, and uses them to record where each connection was made.
/// After the chosen time in the background it stops and lets iOS suspend the app.
@MainActor
@Observable
final class BackgroundKeeper: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = BackgroundKeeper()

    private(set) var authorization: CLAuthorizationStatus
    /// Location updates are on (the app will stay alive in the background).
    private(set) var isActive = false
    /// When background keep-alive will end; nil in the foreground or without a limit.
    private(set) var endsAt: Date?
    private(set) var records: [ConnectionRecord] = []

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var activeChecks: [() -> Bool] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var backgroundSince: Date?
    /// Set when the background time ran out, so it doesn't restart until the app is opened.
    @ObservationIgnored private var expired = false
    @ObservationIgnored private var pendingRecords: Set<UUID> = []
    @ObservationIgnored private let geocoder = CLGeocoder()

    private override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = 500
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .other
        records = Self.loadRecords()

        NotificationCenter.default.addObserver(forName: .conchSessionConnected, object: nil, queue: .main) { [weak self] note in
            let title = note.userInfo?["title"] as? String ?? ""
            let hostname = note.userInfo?["hostname"] as? String ?? ""
            MainActor.assumeIsolated { self?.recordConnection(title: title, hostname: hostname) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: BackgroundKeepSettings.enabledKey)
    }

    /// Recording where connections are made is its own setting, independent of staying alive.
    var recordsLocations: Bool {
        UserDefaults.standard.bool(forKey: BackgroundKeepSettings.recordLocationsKey)
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    /// Adds a source of "is anything connected?" (each window's workspace registers one).
    func register(_ check: @escaping () -> Bool) {
        activeChecks.append(check)
        evaluate()
    }

    /// Call after either setting changes; asks for location permission the first time.
    func settingsChanged() {
        if isEnabled || recordsLocations, authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
        evaluate()
    }

    func appDidEnterBackground() {
        backgroundSince = .now
        evaluate()
    }

    func appDidBecomeActive() {
        backgroundSince = nil
        expired = false
        evaluate()
    }

    private var hasActiveConnections: Bool {
        activeChecks.contains { $0() } || AgentHub.shared.conversations.contains(where: \.isRunning)
    }

    private func evaluate() {
        let minutes = BackgroundKeepSettings.minutes
        if let since = backgroundSince, minutes > 0, isActive,
           Date.now.timeIntervalSince(since) >= TimeInterval(minutes * 60) {
            expired = true
            notifyExpired(minutes: minutes)
        }
        let shouldRun = isEnabled && isAuthorized && hasActiveConnections && !expired
        endsAt = shouldRun ? backgroundSince.flatMap { since in minutes > 0 ? since.addingTimeInterval(TimeInterval(minutes * 60)) : nil } : nil
        guard shouldRun != isActive else { return }
        if shouldRun {
            // Started while in the foreground, updates carry on in the background
            // (with the blue location pill) under When-In-Use permission.
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
        }
        isActive = shouldRun
    }

    private func notifyExpired(minutes: Int) {
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "后台保活已结束")
            content.body = String(localized: "Conch 已在后台保持连接 \(BackgroundKeepSettings.label(minutes: minutes))，连接稍后会断开。回到 Conch 会自动重连。")
            try? await center.add(UNNotificationRequest(identifier: "keepalive-expired", content: content, trigger: nil))
        }
    }

    // MARK: Connection records

    private func recordConnection(title: String, hostname: String) {
        guard recordsLocations, isAuthorized else { return }
        var record = ConnectionRecord(title: title, hostname: hostname, date: .now)
        if let location = manager.location, Date.now.timeIntervalSince(location.timestamp) < 600 {
            record.latitude = location.coordinate.latitude
            record.longitude = location.coordinate.longitude
        } else {
            pendingRecords.insert(record.id)
            manager.requestLocation()
        }
        records.insert(record, at: 0)
        records = Array(records.prefix(200))
        saveRecords()
        if record.latitude != nil { resolvePlace(for: record.id) }
    }

    func clearRecords() {
        records = []
        saveRecords()
    }

    private func resolvePlace(for id: UUID) {
        guard let record = records.first(where: { $0.id == id }), let latitude = record.latitude, let longitude = record.longitude else { return }
        guard !geocoder.isGeocoding else {
            // One lookup at a time; try again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MainActor.assumeIsolated { self?.resolvePlace(for: id) }
            }
            return
        }
        geocoder.reverseGeocodeLocation(CLLocation(latitude: latitude, longitude: longitude)) { [weak self] placemarks, _ in
            guard let place = placemarks?.first else { return }
            var parts: [String] = []
            for part in [place.locality, place.subLocality, place.name].compactMap({ $0 }) where !parts.contains(part) { parts.append(part) }
            MainActor.assumeIsolated {
                guard let self, let index = self.records.firstIndex(where: { $0.id == id }) else { return }
                self.records[index].place = parts.joined(separator: " ")
                self.saveRecords()
            }
        }
    }

    private static func loadRecords() -> [ConnectionRecord] {
        guard let data = UserDefaults.standard.data(forKey: BackgroundKeepSettings.recordsKey) else { return [] }
        return (try? JSONDecoder().decode([ConnectionRecord].self, from: data)) ?? []
    }

    private func saveRecords() {
        UserDefaults.standard.set(try? JSONEncoder().encode(records), forKey: BackgroundKeepSettings.recordsKey)
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        evaluate()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, !pendingRecords.isEmpty else { return }
        for id in pendingRecords {
            guard let index = records.firstIndex(where: { $0.id == id }) else { continue }
            records[index].latitude = location.coordinate.latitude
            records[index].longitude = location.coordinate.longitude
        }
        let filled = pendingRecords
        pendingRecords = []
        saveRecords()
        filled.forEach(resolvePlace)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient (no fix yet); updates keep coming and keep the app alive regardless.
    }
}
#endif
