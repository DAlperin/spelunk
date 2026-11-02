import Foundation

enum Log {
    static let enabled = ProcessInfo.processInfo.environment["SPELUNK_DEBUG"] != nil
    static func debug(_ s: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("[spelunk \(Date().timeIntervalSince1970)] \(s())\n".utf8))
    }
}
