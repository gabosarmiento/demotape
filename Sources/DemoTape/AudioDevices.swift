import AVFoundation

/// Audio input selection for recording. DemoTape can record any audio *input* device — a built-in
/// or USB mic, an aggregate device, or a **virtual/loopback driver** (e.g. BlackHole, Loopback).
/// That last case is how you capture **system audio** on macOS versions that don't expose it to
/// apps (everything before ScreenCaptureKit audio): route system output into the loopback device
/// and pick it here. The recorder just treats the chosen device as "the microphone".
///
/// We store the device's stable `uniqueID` (names aren't unique and can change), and fall back to
/// the system default when the stored device is unset or no longer present.
enum AudioDevices {

    /// All available audio **input** devices, including virtual/loopback drivers. Uses the classic
    /// enumeration because, on macOS, it reliably surfaces virtual devices like BlackHole that a
    /// restricted `DiscoverySession` device-type list can miss.
    static func inputs() -> [AVCaptureDevice] {
        AVCaptureDevice.devices(for: .audio)
    }

    /// The user-selected input device, or the system default when unset / no longer connected.
    static func selected() -> AVCaptureDevice? {
        let id = Settings.audioInputDeviceID
        if !id.isEmpty, let device = AVCaptureDevice(uniqueID: id) { return device }
        return AVCaptureDevice.default(for: .audio)
    }

    /// True when the stored selection is a specific device that is currently connected.
    static func hasExplicitSelection() -> Bool {
        let id = Settings.audioInputDeviceID
        return !id.isEmpty && AVCaptureDevice(uniqueID: id) != nil
    }

    /// Heuristic: does this device look like a loopback/virtual driver usable for system audio?
    /// Used only to hint the UI ("system audio") — never to gate selection.
    static func looksLikeLoopback(_ device: AVCaptureDevice) -> Bool {
        looksLikeLoopback(name: device.localizedName)
    }

    /// Pure, testable core of the loopback heuristic.
    static func looksLikeLoopback(name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("blackhole") || n.contains("loopback") || n.contains("soundflower")
            || n.contains("aggregate") || n.contains("multi-output")
    }
}
