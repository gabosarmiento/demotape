import Foundation
import CoreGraphics

/// The auto-edit engine's data model. A template is a *pacing rule* that emits a `Timeline`
/// of timed events across the entire recording — not a couple of one-off effects. The
/// `TemplateComposer` interprets the timeline frame by frame.
///
/// Design principle: people consume video on TikTok/Reels/Shorts, so edits should feel
/// vibrant and continuously alive — but each template has its OWN coherent rhythm, the way a
/// soccer broadcast, an F1 feed, a reality show, and a commercial each pace themselves
/// differently. Not chaos — a consistent, situation-appropriate cadence.
///
/// All event times are in SOURCE seconds. Speed ramps compress source time into fewer output
/// frames, so the output can be shorter than the source.

enum Angle: Equatable { case screen, webcam }
enum SlideDir: Equatable { case left, right, up, down }
enum Easing: Equatable { case linear, easeIn, easeOut, easeInOut }

extension Easing {
    func apply(_ p: Double) -> Double {
        let x = min(max(p, 0), 1)
        switch self {
        case .linear:    return x
        case .easeIn:    return x * x
        case .easeOut:   return 1 - (1 - x) * (1 - x)
        case .easeInOut: return x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
        }
    }
}

struct EditEvent: Equatable {
    enum Kind: Equatable {
        case cut
        case switchAngle(Angle)
        case zoomIn(CGFloat)
        case zoomOut(CGFloat)
        case punchIn(CGFloat)
        case flipH
        case flipV
        case slide(SlideDir)
        case speedRamp(Double)
        case blurIn
        case blurOut
        case fadeIn
        case fadeToBlack
        case shake(CGFloat)
        case float(CGFloat)
    }
    var start: Double
    var duration: Double
    var kind: Kind
    var easing: Easing = .easeInOut
    var end: Double { start + duration }
}

struct Timeline {
    var events: [EditEvent]
    mutating func add(_ start: Double, _ duration: Double, _ kind: EditEvent.Kind, _ easing: Easing = .easeInOut) {
        events.append(EditEvent(start: start, duration: duration, kind: kind, easing: easing))
    }
}

struct PlanContext {
    let sourceDuration: Double
    let hasWebcam: Bool
}

struct VideoTemplate {
    let id: String
    let name: String
    let persona: String
    let tags: [String]
    let plan: (PlanContext) -> Timeline

    static func byID(_ id: String) -> VideoTemplate? { catalog.first { $0.id == id } }

    // MARK: - Catalog (paced situations)

    static let catalog: [VideoTemplate] = [
        clean, social, sports, race, reality, commercial, keynote, vlog
    ]

    /// Bookend a timeline with a fade in and a fade to black.
    private static func bookend(_ tl: inout Timeline, _ dur: Double, inSec: Double = 0.5, outSec: Double = 0.9) {
        tl.add(0, inSec, .fadeIn, .easeOut)
        tl.add(max(0, dur - outSec), outSec, .fadeToBlack, .easeIn)
    }

    /// Minimal — just a clean fade in/out.
    static let clean = VideoTemplate(
        id: "clean", name: "Clean", persona: "Just polish — no effects, gentle fade in and out.",
        tags: ["Minimal"], plan: { ctx in
            var tl = Timeline(events: [])
            bookend(&tl, ctx.sourceDuration, inSec: 0.6, outSec: 0.8)
            return tl
        })

    /// Social (Reels/TikTok): continuously alive. A subtle always-on push, a punch on a
    /// steady ~2.5s beat, an angle switch every ~7s, and an occasional slide accent.
    static let social = VideoTemplate(
        id: "social", name: "Social", persona: "Reels/TikTok energy — a steady beat of punches and switches that never sits still.",
        tags: ["Vibrant", "Fast"], plan: { ctx in
            var tl = Timeline(events: []); let d = ctx.sourceDuration
            bookend(&tl, d, inSec: 0.35)
            // Always-on gentle push, re-seeded every 8s so it breathes.
            var s = 0.0
            while s < d { let seg = min(8, d - s); tl.add(s, seg, .zoomIn(1.08), .linear); s += seg }
            // Punch on the beat.
            var t = 2.5
            while t < d - 1 { tl.add(t, 0.5, .punchIn(1.12), .easeOut); t += 2.5 }
            // Angle switches (if a webcam angle exists).
            if ctx.hasWebcam {
                var a = 6.0; var cam = true
                while a < d - 2 { tl.add(a, 2.0, .switchAngle(cam ? .webcam : .screen)); cam.toggle(); a += 7 }
            }
            // Slide accents on scene changes.
            var u = 10.0; var dir: SlideDir = .left
            while u < d - 1 { tl.add(u, 0.4, .slide(dir), .easeOut); dir = dir == .left ? .right : .left; u += 10 }
            return tl
        })

    /// Sports broadcast (soccer): calm authority. Wide→cam switches on a slow ~9s cadence,
    /// a smooth push that follows the play, and a replay-style punch every ~14s.
    static let sports = VideoTemplate(
        id: "sports", name: "Sports Broadcast", persona: "Steady, confident coverage — smooth switches and replay-style emphasis.",
        tags: ["Balanced", "Broadcast"], plan: { ctx in
            var tl = Timeline(events: []); let d = ctx.sourceDuration
            bookend(&tl, d)
            var s = 0.0; var cam = false
            while s < d {
                let seg = min(9, d - s)
                if ctx.hasWebcam { tl.add(s, seg, .switchAngle(cam ? .webcam : .screen)); cam.toggle() }
                tl.add(s, seg, .zoomIn(1.07), .easeInOut)   // follow the play
                s += seg
            }
            var t = 14.0
            while t < d - 1 { tl.add(t, 0.7, .punchIn(1.12), .easeOut); t += 14 } // "replay" emphasis
            return tl
        })

    /// Race broadcast (F1): fast and precise. Quick ~5s switches, a zoom pulse every ~4s,
    /// and a couple of speed ramps to sell the pace.
    static let race = VideoTemplate(
        id: "race", name: "Race Broadcast", persona: "High-speed precision — quick switches, tight pulses, and bursts of speed.",
        tags: ["Fast", "Broadcast"], plan: { ctx in
            var tl = Timeline(events: []); let d = ctx.sourceDuration
            bookend(&tl, d, inSec: 0.3)
            var s = 0.0; var cam = false
            while s < d {
                let seg = min(5, d - s)
                if ctx.hasWebcam { tl.add(s, seg, .switchAngle(cam ? .webcam : .screen)); cam.toggle() }
                s += seg
            }
            var t = 3.0
            while t < d - 1 { tl.add(t, 0.5, .punchIn(1.12), .easeOut); t += 4 }
            // Speed bursts ("down the straight").
            var r = 8.0
            while r < d - 4 { tl.add(r, 2.5, .speedRamp(2.0)); r += 16 }
            return tl
        })

    /// Reality show: drama. Long slow push-ins that hold on faces, a sudden punch on
    /// "reveals" every ~11s, and a small shake for tension on the beat.
    static let reality = VideoTemplate(
        id: "reality", name: "Reality Show", persona: "Dramatic tension — slow push-ins that hold, then snap on the reveal.",
        tags: ["Dramatic"], plan: { ctx in
            var tl = Timeline(events: []); let d = ctx.sourceDuration
            bookend(&tl, d, outSec: 1.2)
            var s = 0.0; var inClose = false
            while s < d {
                let seg = min(6, d - s)
                tl.add(s, seg, inClose ? .zoomOut(1.0) : .zoomIn(1.25), .easeInOut) // push in / pull back
                if ctx.hasWebcam && inClose { tl.add(s, seg, .switchAngle(.webcam)) }
                else if ctx.hasWebcam { tl.add(s, seg, .switchAngle(.screen)) }
                inClose.toggle(); s += seg
            }
            var t = 11.0
            while t < d - 1 { tl.add(t, 0.5, .punchIn(1.18), .easeOut); tl.add(t, 0.3, .shake(5), .easeOut); t += 11 }
            return tl
        })

    /// Commercial: premium and rhythmic. A confident slow zoom, a hero punch on a steady
    /// ~3.5s beat, clean slides on scene changes, strong fades.
    static let commercial = VideoTemplate(
        id: "commercial", name: "Commercial", persona: "Premium and rhythmic — hero punches on the beat with clean slides.",
        tags: ["Polished", "Vibrant"], plan: { ctx in
            var tl = Timeline(events: []); let d = ctx.sourceDuration
            bookend(&tl, d, inSec: 0.7, outSec: 1.0)
            var s = 0.0
            while s < d { let seg = min(7, d - s); tl.add(s, seg, .zoomIn(1.06), .easeInOut); s += seg }
            var t = 3.5
            while t < d - 1 { tl.add(t, 0.5, .punchIn(1.13), .easeOut); t += 3.5 }
            var u = 7.0; var dir: SlideDir = .right
            while u < d - 1 { tl.add(u, 0.5, .slide(dir), .easeInOut); dir = dir == .right ? .left : .right; u += 7 }
            return tl
        })

    /// Keynote: measured and professional. Mostly steady with deliberate slow zooms toward
    /// key moments and an occasional switch to the presenter.
    static let keynote = VideoTemplate(
        id: "keynote", name: "Keynote", persona: "Measured and professional — deliberate builds, minimal flash.",
        tags: ["Professional", "Calm"], plan: { ctx in
            var tl = Timeline(events: []); let d = ctx.sourceDuration
            bookend(&tl, d, inSec: 0.8, outSec: 1.0)
            var s = 0.0
            while s < d {
                let seg = min(10, d - s)
                tl.add(s, seg, .zoomIn(1.05), .easeInOut)
                if ctx.hasWebcam, Int(s) % 20 == 0 { tl.add(s, min(3, seg), .switchAngle(.webcam)) }
                s += seg
            }
            var t = 10.0
            while t < d - 1 { tl.add(t, 0.6, .punchIn(1.08), .easeOut); t += 10 }
            return tl
        })

    /// Vlog: personal and warm. Favors the webcam, a gentle handheld float, soft punches.
    static let vlog = VideoTemplate(
        id: "vlog", name: "Vlog", persona: "Personal and warm — camera-forward with a soft handheld feel.",
        tags: ["Personal", "Relaxed"], plan: { ctx in
            var tl = Timeline(events: []); let d = ctx.sourceDuration
            bookend(&tl, d, inSec: 0.6)
            var s = 0.0; var cam = ctx.hasWebcam
            while s < d {
                let seg = min(8, d - s)
                if ctx.hasWebcam { tl.add(s, seg, .switchAngle(cam ? .webcam : .screen)); cam.toggle() }
                tl.add(s, seg, .float(1.2), .easeInOut)      // gentle handheld drift
                tl.add(s, seg, .zoomIn(1.05), .linear)
                s += seg
            }
            var t = 5.0
            while t < d - 1 { tl.add(t, 0.5, .punchIn(1.09), .easeOut); t += 5 }
            return tl
        })
}

/// Tiny deterministic RNG so any "random" pacing is reproducible per render.
struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed != 0 ? seed : 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
    mutating func next(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }
}
