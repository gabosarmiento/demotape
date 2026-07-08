import Foundation

/// Minimal file logger for diagnosing capture issues. Writes to
/// ~/Movies/DemoTape/demotape.log so we can inspect runs launched via `open`.
enum Log {
    private static let queue = DispatchQueue(label: "pro.demotape.log")
    private static let url = Paths.outputDirectory.appendingPathComponent("demotape.log")

    static func write(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        queue.async {
            if let data = line.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                } else {
                    try? data.write(to: url)
                }
            }
        }
    }
}
