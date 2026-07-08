import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

/// Captures a timeline of cursor movement, clicks, scrolls, and keystrokes during a
/// recording. Uses the global+local NSEvent monitor pattern (from Screenize) for
/// discrete events, plus a fixed-rate CGEvent sampler for smooth cursor data.
///
/// Permissions:
/// - Mouse move/click/scroll monitoring needs no special permission.
/// - Global keystroke monitoring requires Accessibility permission; if it isn't
///   granted we still capture everything else and flag `capturedKeystrokes = false`.
final class EventRecorder {

    private let sampleRate: Double = 60.0

    private var startUptime: TimeInterval = 0
    private var displayBounds: CGRect = .zero
    private var pixelSize: CGSize = .zero
    private var scale: Double = 1

    private var cursor: [CursorSample] = []
    private var clicks: [ClickSample] = []
    private var scrolls: [ScrollSample] = []
    private var keys: [KeySample] = []
    private(set) var capturedKeystrokes = false

    private var monitors: [Any] = []
    private var samplingTimer: DispatchSourceTimer?
    private let samplingQueue = DispatchQueue(label: "pro.demotape.events")
    private let lock = NSLock()

    // MARK: - Control

    func start(displayID: CGDirectDisplayID, region: CGRect? = nil) {
        let full = CGDisplayBounds(displayID) // top-left global coordinates
        // Normalize to the recorded region (or the whole display).
        displayBounds = region ?? full
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            scale = full.width > 0 ? Double(mode.pixelWidth) / Double(full.width) : 1
            pixelSize = CGSize(width: displayBounds.width * CGFloat(scale),
                               height: displayBounds.height * CGFloat(scale))
        } else {
            pixelSize = displayBounds.size
            scale = 1
        }
        startUptime = ProcessInfo.processInfo.systemUptime

        // Keystrokes require Accessibility permission. Prompt once if missing.
        capturedKeystrokes = AXIsProcessTrusted()
        if !capturedKeystrokes {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }

        installMonitors()
        startSampling()
        Log.write("EventRecorder: started (keystrokes=\(capturedKeystrokes))")
    }

    /// Stops capture and writes the JSON sidecar next to the given video file.
    @discardableResult
    func stop(videoURL: URL, cameraOffset: Double = 0, eventOffset: Double = 0) -> URL? {
        samplingTimer?.cancel()
        samplingTimer = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()

        let duration = ProcessInfo.processInfo.systemUptime - startUptime

        lock.lock()
        // Drop the stop hotkey (⇧⌘S) so it doesn't render as a badge at the very end.
        keys.removeAll { $0.keyCode == 1 && $0.modifiers.contains("cmd") && $0.modifiers.contains("shift") }
        let metadata = RecordingMetadata(
            startedAt: Date(),
            duration: duration,
            capturedKeystrokes: capturedKeystrokes,
            cameraStartOffset: cameraOffset,
            eventTimeOffset: eventOffset,
            display: DisplayInfo(pointWidth: Double(displayBounds.width),
                                 pointHeight: Double(displayBounds.height),
                                 pixelWidth: Double(pixelSize.width),
                                 pixelHeight: Double(pixelSize.height),
                                 scale: scale),
            cursor: cursor,
            clicks: clicks,
            scrolls: scrolls,
            keys: keys)
        let counts = (cursor.count, clicks.count, scrolls.count, keys.count)
        lock.unlock()

        let sidecar = videoURL.deletingPathExtension().appendingPathExtension("events.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(metadata).write(to: sidecar)
            Log.write("EventRecorder: wrote \(sidecar.lastPathComponent) cursor=\(counts.0) clicks=\(counts.1) scrolls=\(counts.2) keys=\(counts.3)")
        } catch {
            Log.write("EventRecorder: failed to write sidecar: \(error.localizedDescription)")
            return nil
        }

        // Reset for a potential next recording.
        lock.lock()
        cursor.removeAll(); clicks.removeAll(); scrolls.removeAll(); keys.removeAll()
        lock.unlock()

        return sidecar
    }

    // MARK: - Sampling

    private func startSampling() {
        let timer = DispatchSource.makeTimerSource(queue: samplingQueue)
        let interval = 1.0 / sampleRate
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            // CGEvent location is already top-left global coordinates and thread-safe.
            let point = CGEvent(source: nil)?.location ?? .zero
            let n = self.normalize(point)
            let t = ProcessInfo.processInfo.systemUptime - self.startUptime
            self.lock.lock()
            self.cursor.append(CursorSample(t: t, x: n.x, y: n.y))
            self.lock.unlock()
        }
        samplingTimer = timer
        timer.resume()
    }

    // MARK: - Discrete event monitors (global + local)

    private func installMonitors() {
        addMonitor(mask: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.recordClick(event)
        }
        addMonitor(mask: [.scrollWheel]) { [weak self] event in
            self?.recordScroll(event)
        }
        if capturedKeystrokes {
            addMonitor(mask: [.keyDown]) { [weak self] event in
                self?.recordKey(event)
            }
        }
    }

    /// Installs a global+local monitor pair so events are captured whether another
    /// app (global) or DemoTape itself (local) is focused.
    private func addMonitor(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    private func recordClick(_ event: NSEvent) {
        let point = CGEvent(source: nil)?.location ?? .zero
        let n = normalize(point)
        let t = ProcessInfo.processInfo.systemUptime - startUptime
        let button: String
        switch event.type {
        case .leftMouseDown: button = "left"
        case .rightMouseDown: button = "right"
        default: button = "other"
        }
        lock.lock()
        clicks.append(ClickSample(t: t, x: n.x, y: n.y, button: button))
        lock.unlock()
    }

    private func recordScroll(_ event: NSEvent) {
        let point = CGEvent(source: nil)?.location ?? .zero
        let n = normalize(point)
        let t = ProcessInfo.processInfo.systemUptime - startUptime
        lock.lock()
        scrolls.append(ScrollSample(t: t, x: n.x, y: n.y,
                                    dx: Double(event.scrollingDeltaX),
                                    dy: Double(event.scrollingDeltaY)))
        lock.unlock()
    }

    private func recordKey(_ event: NSEvent) {
        let t = ProcessInfo.processInfo.systemUptime - startUptime
        var mods: [String] = []
        let f = event.modifierFlags
        if f.contains(.command) { mods.append("cmd") }
        if f.contains(.shift) { mods.append("shift") }
        if f.contains(.option) { mods.append("opt") }
        if f.contains(.control) { mods.append("ctrl") }
        if f.contains(.function) { mods.append("fn") }
        lock.lock()
        keys.append(KeySample(t: t, keyCode: Int(event.keyCode),
                              chars: event.charactersIgnoringModifiers ?? "",
                              modifiers: mods))
        lock.unlock()
    }

    // MARK: - Helpers

    private func normalize(_ globalTopLeft: CGPoint) -> (x: Double, y: Double) {
        guard displayBounds.width > 0, displayBounds.height > 0 else { return (0, 0) }
        let x = (Double(globalTopLeft.x) - Double(displayBounds.minX)) / Double(displayBounds.width)
        let y = (Double(globalTopLeft.y) - Double(displayBounds.minY)) / Double(displayBounds.height)
        return (min(max(x, 0), 1), min(max(y, 0), 1))
    }

    deinit {
        samplingTimer?.cancel()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
    }
}
