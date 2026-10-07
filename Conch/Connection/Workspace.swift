import Foundation
import Network
import SwiftUI

enum SplitAxis {
    case horizontal // panes side by side
    case vertical // panes stacked
}

/// A tab holds either a browser page or one or more terminal panes (more than
/// one means it's split).
@MainActor
@Observable
final class WorkspaceTab: Identifiable {
    let id = UUID()
    var panes: [TerminalSession]
    let browser: BrowserPage?
    var axis: SplitAxis = .horizontal
    var focusedPaneID: UUID

    init(session: TerminalSession) {
        panes = [session]
        browser = nil
        focusedPaneID = session.id
    }

    init(browser: BrowserPage) {
        panes = []
        self.browser = browser
        focusedPaneID = browser.id
    }

    var focusedPane: TerminalSession? {
        panes.first { $0.id == focusedPaneID } ?? panes.first
    }

    var title: String {
        browser?.displayTitle ?? focusedPane?.title ?? ""
    }
}

/// All open tabs in a window.
@MainActor
@Observable
final class Workspace {
    static let maxPanes = 4

    var tabs: [WorkspaceTab] = []
    /// The server-status sheet, when open.
    var monitorRequest: MonitorRequest?
    var selectedTabID: UUID? {
        didSet {
            guard let selectedTabID else { return }
            recentTabIDs.removeAll { $0 == selectedTabID }
            recentTabIDs.append(selectedTabID)
        }
    }
    /// Tabs in the order they were last selected, most recent last.
    @ObservationIgnored private var recentTabIDs: [UUID] = []

    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var wasOffline = false

    init() {
        // When the network comes back, retry dropped sessions right away instead of
        // waiting out the backoff.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                if path.status == .satisfied, self.wasOffline { self.checkConnections() }
                self.wasOffline = path.status != .satisfied
            }
        }
        pathMonitor.start(queue: .global(qos: .utility))
    }

    var allSessions: [TerminalSession] {
        tabs.flatMap(\.panes)
    }

    /// Probes live sessions and retries dropped ones (foreground, network change).
    func checkConnections() {
        allSessions.forEach { $0.checkConnection() }
    }

    var selectedTab: WorkspaceTab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// Goes to the host's tab if one is open (the one used last), reconnecting it if
    /// it dropped; otherwise opens a tab for it.
    func open(_ host: Host) {
        let candidates = tabs.filter { $0.panes.contains { $0.target.hostID == host.id } }
        guard let tab = candidates.max(by: { recency($0) < recency($1) }) else {
            openNewTab(host)
            return
        }
        host.lastConnectedAt = .now
        selectedTabID = tab.id
        if let pane = tab.panes.first(where: { $0.target.hostID == host.id }) {
            tab.focusedPaneID = pane.id
            if !pane.state.isActive { pane.connect() }
        }
    }

    /// Always opens another tab, even if the host already has one.
    func openNewTab(_ host: Host) {
        host.lastConnectedAt = .now
        open(ConnectionTarget(host: host))
    }

    /// Another tab like `tab`: the same server, or a fresh browser page (the + in the tab bar).
    func duplicate(_ tab: WorkspaceTab) {
        if tab.browser != nil {
            openBrowser(after: tab)
            return
        }
        guard let target = tab.focusedPane?.target else { return }
        open(target, after: tab)
    }

    var browserPages: [BrowserPage] {
        tabs.compactMap(\.browser)
    }

    /// The browser tab on screen, or else the one used most recently.
    var currentBrowserTab: WorkspaceTab? {
        if let tab = selectedTab, tab.browser != nil { return tab }
        return tabs.filter { $0.browser != nil }.max { recency($0) < recency($1) }
    }

    func tab(for page: BrowserPage) -> WorkspaceTab? {
        tabs.first { $0.browser?.id == page.id }
    }

    /// Opens a browser tab, next to the current tab, and loads `url` if given.
    @discardableResult
    func openBrowser(_ url: URL? = nil, after neighbor: WorkspaceTab? = nil) -> BrowserPage {
        let page = BrowserPage()
        let tab = WorkspaceTab(browser: page)
        let anchor = neighbor ?? selectedTab
        let index = anchor.flatMap { anchor in tabs.firstIndex { $0.id == anchor.id } }
        tabs.insert(tab, at: index.map { $0 + 1 } ?? tabs.count)
        selectedTabID = tab.id
        if let url { page.load(url) }
        return page
    }

    private func open(_ target: ConnectionTarget, after neighbor: WorkspaceTab? = nil) {
        let session = TerminalSession(target: target)
        let tab = WorkspaceTab(session: session)
        // Next to its sibling, so tabs for one server stay together.
        let index = neighbor.flatMap { neighbor in tabs.lastIndex { $0.focusedPane?.target.hostID == neighbor.focusedPane?.target.hostID } }
        tabs.insert(tab, at: index.map { $0 + 1 } ?? tabs.count)
        selectedTabID = tab.id
        session.connect()
    }

    private func recency(_ tab: WorkspaceTab) -> Int {
        recentTabIDs.firstIndex(of: tab.id) ?? -1
    }

    /// "服务器 2" for the second tab to the same server, so they can be told apart.
    func title(of tab: WorkspaceTab) -> String {
        guard let hostID = tab.focusedPane?.target.hostID else { return tab.title }
        let siblings = tabs.filter { $0.focusedPane?.target.hostID == hostID }
        guard siblings.count > 1, let position = siblings.firstIndex(where: { $0.id == tab.id }), position > 0 else { return tab.title }
        return "\(tab.title) \(position + 1)"
    }

    /// Opens a second connection to the focused pane's host alongside it.
    func split(_ tab: WorkspaceTab, axis: SplitAxis) {
        guard let source = tab.focusedPane, tab.panes.count < Self.maxPanes else { return }
        let session = TerminalSession(target: source.target)
        tab.axis = axis
        let index = (tab.panes.firstIndex { $0.id == source.id } ?? tab.panes.count - 1) + 1
        tab.panes.insert(session, at: index)
        tab.focusedPaneID = session.id
        session.connect()
    }

    func close(pane session: TerminalSession, in tab: WorkspaceTab) {
        session.disconnect()
        tab.panes.removeAll { $0.id == session.id }
        if tab.panes.isEmpty {
            close(tab)
        } else if tab.focusedPaneID == session.id, let first = tab.panes.first {
            tab.focusedPaneID = first.id
        }
    }

    func close(_ tab: WorkspaceTab) {
        tab.panes.forEach { $0.disconnect() }
        tab.browser?.close()
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        recentTabIDs.removeAll { $0 == tab.id }
        if selectedTabID == tab.id {
            // Back to the tab used before this one, like closing a browser tab.
            selectedTabID = recentTabIDs.last ?? (tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id)
        }
    }

    func closeFocused() {
        guard let tab = selectedTab else { return }
        if let pane = tab.focusedPane { close(pane: pane, in: tab) } else { close(tab) }
    }

    func selectTab(offset: Int) {
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        selectedTabID = tabs[(current + offset + tabs.count) % tabs.count].id
    }

    func selectTab(number: Int) {
        guard number >= 1, number <= tabs.count else { return }
        selectedTabID = tabs[number - 1].id
    }

    func isConnected(_ host: Host) -> Bool {
        tabs.contains { $0.panes.contains { $0.target.hostID == host.id && $0.state == .connected } }
    }
}
