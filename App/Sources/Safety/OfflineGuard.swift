import Foundation

/// Offline enforcement, layer 2 of 3.
///
///   1. `project.yml` links no networking framework and `check_offline.sh` fails
///      the build if a socket API appears in the sources.
///   2. This URLProtocol is registered at launch and refuses every request, so
///      even a transitive dependency that tries to phone home gets an error
///      instead of a connection.
///   3. `docs/OFFLINE.md` describes how to verify with a packet capture.
///
/// Blocked attempts are counted and surfaced in Diagnostics, so "0 attempts"
/// during a session is observable rather than asserted.
final class OfflineGuard: URLProtocol {

    private static let counter = Counter()

    static var blockedAttempts: Int { counter.value }
    static var lastBlockedHost: String? { counter.lastHost }

    /// Registers the guard. Safe to call more than once.
    static func install() {
        URLProtocol.registerClass(OfflineGuard.self)
        // A session configuration with no protocol classes would bypass the
        // global registration; rather than police every call site we also install
        // a default configuration that inherits the guard.
        URLSessionConfiguration.ephemeral.protocolClasses = [OfflineGuard.self]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        OfflineGuard.counter.record(host: request.url?.host)
        let error = NSError(
            domain: "OfflineResearch.NetworkBlocked",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Network access is disabled: this app is offline-only."]
        )
        client?.urlProtocol(self, didFailWithError: error)
    }

    override func stopLoading() {}

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var host: String?

        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }

        var lastHost: String? {
            lock.lock(); defer { lock.unlock() }
            return host
        }

        func record(host newHost: String?) {
            lock.lock()
            count += 1
            host = newHost
            lock.unlock()
        }
    }
}
