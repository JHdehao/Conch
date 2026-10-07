import Foundation

/// Which saved computers answer right now, for choosing one to work on. Only checks
/// that an SSH server responds (`ConnectionDoctor.reachability`); nothing logs in.
@MainActor
@Observable
final class HostReachability {
    static let shared = HostReachability()

    enum Status: Equatable {
        case checking
        case online
        case offline(String)
    }

    private(set) var statuses: [UUID: Status] = [:]
    @ObservationIgnored private var checkedAt: [UUID: Date] = [:]

    /// Checks, side by side, every host not checked within `maxAge` seconds.
    func refresh(_ hosts: [Host], maxAge: TimeInterval = 60) async {
        let due = hosts.filter { host in
            statuses[host.id] != .checking && (checkedAt[host.id].map { $0.timeIntervalSinceNow < -maxAge } ?? true)
        }
        guard !due.isEmpty else { return }
        for host in due { statuses[host.id] = .checking }
        let targets = due.map { (id: $0.id, hostname: $0.hostname, port: $0.port) }
        await withTaskGroup(of: (UUID, String?).self) { group in
            for target in targets {
                group.addTask { (target.id, await ConnectionDoctor.reachability(host: target.hostname, port: target.port)) }
            }
            for await (id, problem) in group {
                statuses[id] = problem.map(Status.offline) ?? .online
                checkedAt[id] = .now
            }
        }
    }
}
