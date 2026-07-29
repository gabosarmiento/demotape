import XCTest
import AVFoundation
@testable import DemoTape

/// End-to-end check that the crop/scale encode actually runs and produces a file at the exact
/// target size (the pure crop math is covered separately in PlatformFitTests).
final class PlatformCropEncodeTests: XCTestCase {

    func testCropsAndScalesToTargetSize() throws {
        let tmp = FileManager.default.temporaryDirectory
        let srcURL = tmp.appendingPathComponent("pc-src-\(UUID().uuidString).mp4")
        let outURL = tmp.appendingPathComponent("pc-out-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: srcURL); try? FileManager.default.removeItem(at: outURL) }

        try makeSolidVideo(at: srcURL, size: CGSize(width: 320, height: 180), frames: 12)

        try PlatformCrop().export(source: srcURL, to: outURL,
                                  targetSize: CGSize(width: 1080, height: 1920)) { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
        let track = AVAsset(url: outURL).tracks(withMediaType: .video).first
        let size = track?.naturalSize ?? .zero
        XCTAssertEqual(size.width, 1080, accuracy: 2)
        XCTAssertEqual(size.height, 1920, accuracy: 2)
    }

    /// Writes a short solid-gray H.264 clip at `size`.
    private func makeSolidVideo(at url: URL, size: CGSize, frames: Int) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Int(size.width),
            kCVPixelBufferHeightKey: Int(size.height)
        ] as CFDictionary, &pool)
        for i in 0..<frames {
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &pb)
            guard let pb = pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                memset(base, 128, CVPixelBufferGetBytesPerRow(pb) * Int(size.height))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            while !input.isReadyForMoreMediaData { usleep(1000) }
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 12))
        }
        input.markAsFinished()
        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
        XCTAssertEqual(writer.status, .completed)
    }
}
