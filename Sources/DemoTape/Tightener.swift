import Foundation
import AVFoundation

/// Local, no-AI "tighten" pass: remove silent gaps and/or speed the video up (pitch-preserved).
/// Produces a new `…tight.mp4`. Silence detection is simple loudness analysis (like the
/// jump-cut feature in social video editors) — no network, no cost.
final class Tightener {

    struct Options {
        /// Remove pauses where the audio stays quiet longer than `minSilence`.
        var removeSilence: Bool = true
        /// Loudness threshold; windows quieter than this (dBFS) count as silent.
        var silenceThresholdDb: Float = -40
        /// Only gaps at least this long (seconds) are cut.
        var minSilence: Double = 0.6
        /// Keep this much silence on each side of kept content, so cuts aren't abrupt.
        var padding: Double = 0.12
        /// Playback speed multiplier (1.0 = unchanged). Audio pitch is preserved.
        var speed: Double = 1.0
    }

    enum TightenError: LocalizedError {
        case noVideoTrack, exportFailed(String), nothingToDo
        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "The video has no video track."
            case .exportFailed(let m): return "Export failed: \(m)"
            case .nothingToDo: return "Nothing to trim or speed up."
            }
        }
    }

    struct Range { var start: Double; var end: Double }

    /// Result summary (useful for UI + tests).
    struct Summary { var originalDuration: Double; var outputDuration: Double; var cuts: Int }

    // MARK: - Silence analysis (pure enough to test)

    /// Given per-window loudness flags (`isLoud`) at `windowDuration` resolution over a clip of
    /// `duration` seconds, returns the time ranges to KEEP: non-silent spans, with silent gaps
    /// longer than `minSilence` trimmed down to `padding` on each side.
    static func keepRanges(isLoud: [Bool], windowDuration: Double, duration: Double,
                           minSilence: Double, padding: Double) -> [Range] {
        guard !isLoud.isEmpty else { return [Range(start: 0, end: duration)] }

        // Find maximal silent runs.
        var cuts: [Range] = []
        var i = 0
        while i < isLoud.count {
            if isLoud[i] { i += 1; continue }
            var j = i
            while j < isLoud.count && !isLoud[j] { j += 1 }
            let silStart = Double(i) * windowDuration
            let silEnd = min(Double(j) * windowDuration, duration)
            if silEnd - silStart >= minSilence {
                // Keep `padding` only next to actual content. Silence at the very start or end
                // of the clip has no content on the outer side, so trim it flush.
                let atStart = (i == 0)
                let atEnd = (j >= isLoud.count)
                let cutStart = atStart ? silStart : silStart + padding
                let cutEnd = atEnd ? silEnd : silEnd - padding
                if cutEnd > cutStart { cuts.append(Range(start: cutStart, end: cutEnd)) }
            }
            i = j
        }
        if cuts.isEmpty { return [Range(start: 0, end: duration)] }

        // Keep ranges = complement of cuts within [0, duration].
        var keep: [Range] = []
        var cursor = 0.0
        for cut in cuts {
            if cut.start > cursor { keep.append(Range(start: cursor, end: cut.start)) }
            cursor = cut.end
        }
        if cursor < duration { keep.append(Range(start: cursor, end: duration)) }
        return keep.filter { $0.end - $0.start > 0.02 }
    }

    // MARK: - Main

    @discardableResult
    func tighten(video: URL, options: Options, to outURL: URL) throws -> Summary {
        let asset = AVAsset(url: video)
        guard let vTrack = asset.tracks(withMediaType: .video).first else { throw TightenError.noVideoTrack }
        let aTrack = asset.tracks(withMediaType: .audio).first
        let duration = CMTimeGetSeconds(asset.duration)

        // Decide keep-ranges.
        let ranges: [Range]
        if options.removeSilence, let aTrack = aTrack {
            let (flags, win) = try analyzeLoudness(asset: asset, track: aTrack,
                                                   thresholdDb: options.silenceThresholdDb)
            ranges = Self.keepRanges(isLoud: flags, windowDuration: win, duration: duration,
                                     minSilence: options.minSilence, padding: options.padding)
        } else {
            ranges = [Range(start: 0, end: duration)]
        }
        let cutsRemoved = max(0, ranges.count - 1)
        let willTrim = ranges.count > 1 || (ranges.first.map { $0.start > 0.02 || $0.end < duration - 0.02 } ?? false)
        guard willTrim || options.speed != 1.0 else { throw TightenError.nothingToDo }

        // Build the trimmed composition.
        let comp = AVMutableComposition()
        guard let vComp = comp.addMutableTrack(withMediaType: .video,
                                               preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw TightenError.exportFailed("video track")
        }
        vComp.preferredTransform = vTrack.preferredTransform
        let aComp = aTrack != nil ? comp.addMutableTrack(withMediaType: .audio,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        var cursor = CMTime.zero
        for r in ranges {
            let cmRange = CMTimeRange(start: CMTime(seconds: r.start, preferredTimescale: 600),
                                      duration: CMTime(seconds: r.end - r.start, preferredTimescale: 600))
            try vComp.insertTimeRange(cmRange, of: vTrack, at: cursor)
            if let aComp = aComp, let aTrack = aTrack {
                try aComp.insertTimeRange(cmRange, of: aTrack, at: cursor)
            }
            cursor = cursor + cmRange.duration
        }

        // Optional speed-up (scale the whole composition; pitch preserved at export).
        var trimmedDuration = CMTimeGetSeconds(cursor)
        if options.speed != 1.0 && cursor.seconds > 0 {
            let scaled = CMTime(seconds: trimmedDuration / options.speed, preferredTimescale: 600)
            comp.scaleTimeRange(CMTimeRange(start: .zero, duration: cursor), toDuration: scaled)
            trimmedDuration = CMTimeGetSeconds(scaled)
        }

        // Export. Passthrough when we're only concatenating; re-encode when time-scaling.
        let preset = options.speed != 1.0 ? AVAssetExportPresetHighestQuality : AVAssetExportPresetPassthrough
        try? FileManager.default.removeItem(at: outURL)
        guard let export = AVAssetExportSession(asset: comp, presetName: preset) else {
            throw TightenError.exportFailed("no export session")
        }
        export.outputURL = outURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        export.audioTimePitchAlgorithm = .spectral   // keep the voice natural when sped up
        let sema = DispatchSemaphore(value: 0)
        export.exportAsynchronously { sema.signal() }
        sema.wait()
        guard export.status == .completed else {
            throw TightenError.exportFailed(export.error?.localizedDescription ?? "status \(export.status.rawValue)")
        }
        Log.write("Tightener: \(String(format: "%.1f", duration))s -> \(String(format: "%.1f", trimmedDuration))s "
                  + "(\(cutsRemoved) cuts, \(options.speed)x) -> \(outURL.lastPathComponent)")
        return Summary(originalDuration: duration, outputDuration: trimmedDuration, cuts: cutsRemoved)
    }

    // MARK: - Loudness reader

    /// Reads the audio as mono 16 kHz PCM and returns a per-window loudness flag array.
    private func analyzeLoudness(asset: AVAsset, track: AVAssetTrack,
                                 thresholdDb: Float) throws -> (isLoud: [Bool], window: Double) {
        let reader = try AVAssetReader(asset: asset)
        let sampleRate = 16000.0
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(out)
        reader.startReading()

        let windowSamples = Int(sampleRate * 0.03)   // 30 ms windows
        var flags: [Bool] = []
        var acc: [Int16] = []
        acc.reserveCapacity(windowSamples * 2)

        func flush(force: Bool) {
            while acc.count >= windowSamples || (force && !acc.isEmpty) {
                let n = min(windowSamples, acc.count)
                var sum = 0.0
                for k in 0..<n { let v = Double(acc[k]); sum += v * v }
                let rms = sqrt(sum / Double(n))
                let db = rms > 0 ? 20 * log10(rms / 32768.0) : -120.0
                flags.append(Float(db) >= thresholdDb)
                acc.removeFirst(n)
                if force && acc.isEmpty { break }
            }
        }

        while reader.status == .reading {
            guard let sb = out.copyNextSampleBuffer() else { break }
            if let bb = CMSampleBufferGetDataBuffer(sb) {
                var length = 0
                var dataPtr: UnsafeMutablePointer<Int8>?
                CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                            totalLengthOut: &length, dataPointerOut: &dataPtr)
                if let dataPtr = dataPtr, length > 0 {
                    let count = length / MemoryLayout<Int16>.size
                    dataPtr.withMemoryRebound(to: Int16.self, capacity: count) { p in
                        acc.append(contentsOf: UnsafeBufferPointer(start: p, count: count))
                    }
                }
            }
            CMSampleBufferInvalidate(sb)
            flush(force: false)
        }
        flush(force: true)
        return (flags, 0.03)
    }
}
