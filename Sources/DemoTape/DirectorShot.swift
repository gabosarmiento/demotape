import Foundation

/// The switcher's palette, expressed through DemoTape's two real feeds — the **styled screen
/// program** (already cinematic: cursor, click-zoom, ripples, PiP) and the **raw presenter**
/// (webcam). A director builds a demo by sequencing these shots with camera moves.
enum ShotFraming: String, Codable {
    case screen           // the styled screen program (full) — includes its own click-zoom + PiP
    case presenterFull    // full presenter (webcam), medium framing
    case presenterClose   // tight presenter close-up (cropped, with headroom)
    case split            // two-shot: screen and presenter side by side
}

/// Camera-move modifiers. Pans are always left→right (the direction audiences read as natural).
enum ShotMove: String, Codable {
    case still
    case pushIn
    case panRight
}

/// One take: a framing + move held for a time range (source seconds).
struct DirectorShot: Codable, Equatable {
    var start: Double
    var end: Double
    var framing: ShotFraming
    var move: ShotMove
}

/// A genre grammar: the same shot vocabulary, paced and framed differently — the way a keynote,
/// a social clip, and a commercial each carry themselves.
enum DirectorGenre: String, CaseIterable {
    case clean, keynote, social, commercial, vlog

    var title: String {
        switch self {
        case .clean: return "Clean"
        case .keynote: return "Keynote"
        case .social: return "Social"
        case .commercial: return "Commercial"
        case .vlog: return "Vlog"
        }
    }
    var blurb: String {
        switch self {
        case .clean: return "Minimal and professional — mostly screen, a calm sign-off on camera."
        case .keynote: return "Measured and confident — presenter for the explaining, slow push-ins, splits for demos."
        case .social: return "Fast and punchy — frequent close-ups and energy, made to hold attention."
        case .commercial: return "Premium and dynamic — hero push-ins and close-ups on the key lines."
        case .vlog: return "Warm and personal — camera-forward, relaxed pacing."
        }
    }

    struct Params {
        var minCalmGap: Double
        var maxPresenterShot: Double
        var minScreenRun: Double
        var closeUpEvery: Int   // every Nth presenter shot is a tight close-up
        var splitEvery: Int     // every Nth presenter shot is a split two-shot (0 = never)
        var move: ShotMove
    }
    var params: Params {
        switch self {
        case .clean:      return .init(minCalmGap: 4, maxPresenterShot: 4, minScreenRun: 9, closeUpEvery: 99, splitEvery: 0,  move: .still)
        case .keynote:    return .init(minCalmGap: 3, maxPresenterShot: 6, minScreenRun: 6, closeUpEvery: 3,  splitEvery: 2,  move: .pushIn)
        case .social:     return .init(minCalmGap: 2, maxPresenterShot: 4, minScreenRun: 4, closeUpEvery: 2,  splitEvery: 4,  move: .pushIn)
        case .commercial: return .init(minCalmGap: 3, maxPresenterShot: 5, minScreenRun: 5, closeUpEvery: 2,  splitEvery: 3,  move: .pushIn)
        case .vlog:       return .init(minCalmGap: 2.5, maxPresenterShot: 6, minScreenRun: 4, closeUpEvery: 2, splitEvery: 3, move: .panRight)
        }
    }
}

/// Builds and cleans shot sequences shared by the local, AI, and genre directors.
enum ShotPlanner {

    /// A genre-styled plan: presenter shots at natural pauses, framed and paced per the genre.
    static func genre(_ genre: DirectorGenre, metadata: RecordingMetadata,
                      hasWebcam: Bool, duration: Double) -> [DirectorShot] {
        guard hasWebcam else { return [DirectorShot(start: 0, end: duration, framing: .screen, move: .still)] }
        let p = genre.params
        let dirParams = AutoDirector.Params(minCalmGap: p.minCalmGap, maxWebcamShot: p.maxPresenterShot,
                                            minScreenRun: p.minScreenRun, minWebcamShot: 2.5)
        let segs = AutoDirector.calmGapSegments(metadata: metadata, duration: duration, params: dirParams)
        var presenter = [DirectorShot]()
        for (i, seg) in segs.enumerated() {
            let framing: ShotFraming
            if p.closeUpEvery > 0 && (i + 1) % p.closeUpEvery == 0 { framing = .presenterClose }
            else if p.splitEvery > 0 && (i + 1) % p.splitEvery == 0 { framing = .split }
            else { framing = .presenterFull }
            let move: ShotMove = (framing == .split) ? .still : p.move
            presenter.append(DirectorShot(start: seg.start, end: seg.end, framing: framing, move: move))
        }
        return fillWithScreen(presenter, duration: duration)
    }


    /// Local (no-network) plan: hold the screen while working, and on pauses cut to the presenter
    /// with varied framing and motion — a full-screen push-in, a close-up pan, or a split two-shot.
    static func local(metadata: RecordingMetadata, hasWebcam: Bool, duration: Double) -> [DirectorShot] {
        guard hasWebcam else { return [DirectorShot(start: 0, end: duration, framing: .screen, move: .still)] }
        let segs = AutoDirector.calmGapSegments(metadata: metadata, duration: duration)
        var presenter = [DirectorShot]()
        for (i, seg) in segs.enumerated() {
            let framing: ShotFraming
            let move: ShotMove
            switch i % 3 {
            case 0: framing = .presenterFull;  move = .pushIn
            case 1: framing = .presenterClose; move = .panRight
            default: framing = .split;         move = .still
            }
            presenter.append(DirectorShot(start: seg.start, end: seg.end, framing: framing, move: move))
        }
        return fillWithScreen(presenter, duration: duration)
    }

    /// Cleans an arbitrary set of shots (e.g. from the AI) into an ordered, gap-free sequence:
    /// clamps, drops too-short shots, sorts, removes overlaps, and fills any gaps with the screen.
    static func sanitize(_ shots: [DirectorShot], duration: Double, minShot: Double = 2.0) -> [DirectorShot] {
        let cleaned = shots
            .map { DirectorShot(start: max(0, min($0.start, $0.end)),
                                end: min(duration, max($0.start, $0.end)),
                                framing: $0.framing, move: $0.move) }
            .filter { $0.end - $0.start >= minShot && $0.framing != .screen }
            .sorted { $0.start < $1.start }
        // Drop overlaps (keep the earlier shot).
        var nonOverlapping = [DirectorShot]()
        var lastEnd = 0.0
        for s in cleaned where s.start >= lastEnd {
            nonOverlapping.append(s)
            lastEnd = s.end
        }
        return fillWithScreen(nonOverlapping, duration: duration)
    }

    /// Fills the timeline around presenter shots with screen shots so every second is covered.
    private static func fillWithScreen(_ presenterShots: [DirectorShot], duration: Double) -> [DirectorShot] {
        guard duration > 0 else { return [] }
        var out = [DirectorShot]()
        var cursor = 0.0
        for s in presenterShots.sorted(by: { $0.start < $1.start }) {
            if s.start > cursor + 0.05 {
                out.append(DirectorShot(start: cursor, end: s.start, framing: .screen, move: .still))
            }
            out.append(s)
            cursor = s.end
        }
        if cursor < duration - 0.05 {
            out.append(DirectorShot(start: cursor, end: duration, framing: .screen, move: .still))
        }
        return out.isEmpty ? [DirectorShot(start: 0, end: duration, framing: .screen, move: .still)] : out
    }
}
