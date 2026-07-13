import Foundation
import AVFoundation

/// Shared audio I/O for the offline audio-processing steps (noise suppression, voice
/// enhancement): read a video's audio into Float channels, write Float channels to AAC, and
/// mux an audio file back over a video with **video passthrough** (no re-encode).
enum AudioTrackIO {

    enum IOError: LocalizedError {
        case noAudio, failed(String)
        var errorDescription: String? {
            switch self {
            case .noAudio: return "The video has no audio track."
            case .failed(let m): return "Audio processing failed: \(m)"
            }
        }
    }

    /// Reads the first audio track into deinterleaved Float channels + sample rate.
    static func readChannels(from asset: AVAsset) throws -> (channels: [[Float]], sampleRate: Double) {
        guard let track = asset.tracks(withMediaType: .audio).first else { throw IOError.noAudio }
        let desc = (track.formatDescriptions.first as! CMAudioFormatDescription)
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)!.pointee
        let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000
        let channelCount = max(1, Int(asbd.mChannelsPerFrame))

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw IOError.failed(reader.error?.localizedDescription ?? "reader") }

        var interleaved = [Float]()
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var dataPtr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &length, dataPointerOut: &dataPtr)
            if let dataPtr = dataPtr {
                let count = length / MemoryLayout<Float>.size
                dataPtr.withMemoryRebound(to: Float.self, capacity: count) { fp in
                    interleaved.append(contentsOf: UnsafeBufferPointer(start: fp, count: count))
                }
            }
            CMSampleBufferInvalidate(sample)
        }
        if reader.status == .failed { throw IOError.failed(reader.error?.localizedDescription ?? "read") }

        var channels = [[Float]](repeating: [], count: channelCount)
        let frames = interleaved.count / channelCount
        for c in 0..<channelCount {
            var ch = [Float](repeating: 0, count: frames)
            for i in 0..<frames { ch[i] = interleaved[i * channelCount + c] }
            channels[c] = ch
        }
        return (channels, sampleRate)
    }

    /// Writes Float channels to an AAC `.m4a` file.
    static func writeAAC(channels: [[Float]], sampleRate: Double, to url: URL) throws {
        let channelCount = max(1, channels.count)
        let frames = channels.map { $0.count }.max() ?? 0
        guard frames > 0 else { throw IOError.failed("empty audio") }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: 128_000
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channelCount)) else {
            throw IOError.failed("format")
        }
        let chunk = 16384
        var offset = 0
        while offset < frames {
            let this = min(chunk, frames - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(this)) else { break }
            buffer.frameLength = AVAudioFrameCount(this)
            for c in 0..<channelCount {
                let dst = buffer.floatChannelData![c]
                let src = channels[c]
                for i in 0..<this { dst[i] = i + offset < src.count ? src[i + offset] : 0 }
            }
            try file.write(from: buffer)
            offset += this
        }
    }

    /// Copies the video track (no re-encode) and attaches `audio`.
    static func mux(video: URL, audio: URL, to out: URL) throws {
        let comp = AVMutableComposition()
        let videoAsset = AVAsset(url: video)
        let audioAsset = AVAsset(url: audio)
        let range = CMTimeRange(start: .zero, duration: videoAsset.duration)

        if let v = videoAsset.tracks(withMediaType: .video).first,
           let vComp = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try vComp.insertTimeRange(range, of: v, at: .zero)
            vComp.preferredTransform = v.preferredTransform
        }
        if let a = audioAsset.tracks(withMediaType: .audio).first,
           let aComp = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let aDur = min(audioAsset.duration, videoAsset.duration)
            try aComp.insertTimeRange(CMTimeRange(start: .zero, duration: aDur), of: a, at: .zero)
        }

        try? FileManager.default.removeItem(at: out)
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw IOError.failed("no export session")
        }
        export.outputURL = out
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        let sema = DispatchSemaphore(value: 0)
        export.exportAsynchronously { sema.signal() }
        sema.wait()
        guard export.status == .completed else {
            throw IOError.failed(export.error?.localizedDescription ?? "export \(export.status.rawValue)")
        }
    }
}
