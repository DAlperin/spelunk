import Foundation

/// Logs every main-thread stall longer than `threshold`, tagged with the last debug-bridge command.
/// A background thread pings the main queue every 10ms; a ping answered late is a stall.
final class StallMonitor: @unchecked Sendable {
    static let shared = StallMonitor()
    private let lock = NSLock()
    private var lastCommand = ""
    private let threshold = 0.05

    func note(_ command: String) { lock.withLock { lastCommand = command } }

    func start() {
        let t = Thread { [self] in
            while true {
                let sent = Date()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                answered.wait()
                let waited = Date().timeIntervalSince(sent)
                if waited > threshold {
                    let cmd = lock.withLock { lastCommand }
                    Log.debug("stall \(Int(waited * 1000))ms after \(cmd)")
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        t.qualityOfService = .userInteractive
        t.start()
    }
}
