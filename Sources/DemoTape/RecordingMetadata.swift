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
    /// Which pointer the system was showing: `"arrow"`, `"hand"`, `"ibeam"`, `"resize"`.
    ///
    /// Recorded so the styled video can switch shape the way the real pointer does — a hand over a
    /// button, a text bar over a field. Drawing one arrow for the whole take loses a signal the
    /// viewer reads unconsciously: the hand is what says "this is clickable". Optional so sidecars
    /// recorded before this existed still decode (they render as an arrow).
    var kind: String?
}

/// The pointer shapes the renderer can draw. Kept deliberately small: these are the ones that carry
/// meaning in a product demo. Anything else falls back to the arrow.
enum CursorKind: String {
    case arrow, hand, ibeam, resize

    init(rawValueOrArrow raw: String?) {
        self = CursorKind(rawValue: raw ?? "") ?? .arrow
    }
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
    /// Where the text is being entered, normalized to the display (top-left origin), when known.
    ///
    /// Real keystrokes carry no position, so typing normally anchors the camera on the click that
    /// focused the field. That's correct for a short entry, but a long sentence grows past the edge
    /// of a zoomed frame — the words being typed leave the shot. When a driver reports the caret's
    /// position, the camera can follow the text instead of staring at where the field started.
    /// Optional so existing sidecars still decode.
    var x: Double?
    var y: Double?
}
