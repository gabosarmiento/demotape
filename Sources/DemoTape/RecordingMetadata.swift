import Foundation

/// Event timeline captured alongside a recording. Saved as a JSON sidecar next to
/// the .mov so the Phase 3 auto-editor can drive zoom/cursor/keystroke effects.
///
/// All positions are normalized to the recorded display: x and y in 0...1 with a
/// top-left origin, so they map onto any output video size. Times (`t`) are seconds
/// from the start of the recording.
struct RecordingMetadata: Codable {
    var version: Int = 1
    var startedAt: Date
    var duration: Double
    var capturedKeystrokes: Bool
    /// Seconds the webcam recording started after the screen recording (for PiP sync).
    /// Optional so older sidecar files (without this key) still decode.
    var cameraStartOffset: Double?
    /// Seconds the video's first frame lags the event-timeline clock (cursor alignment).
    var eventTimeOffset: Double?
    var display: DisplayInfo
    var cursor: [CursorSample]
    var clicks: [ClickSample]
    var scrolls: [ScrollSample]
    var keys: [KeySample]
}

struct DisplayInfo: Codable {
    var pointWidth: Double
    var pointHeight: Double
    var pixelWidth: Double
    var pixelHeight: Double
    var scale: Double
}

/// Uniformly sampled cursor position (normalized, top-left origin).
struct CursorSample: Codable {
    var t: Double
    var x: Double
    var y: Double
}

struct ClickSample: Codable {
    var t: Double
    var x: Double
    var y: Double
    var button: String   // "left" | "right" | "other"
}

struct ScrollSample: Codable {
    var t: Double
    var x: Double
    var y: Double
    var dx: Double
    var dy: Double
}

struct KeySample: Codable {
    var t: Double
    var keyCode: Int
    var chars: String
    var modifiers: [String]   // e.g. ["cmd", "shift"]
}
