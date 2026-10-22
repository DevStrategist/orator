import XCTest
import AVFoundation
import OratorCore
@testable import OratorCapture

final class RecorderTests: XCTestCase {
    func testStoppingCaptureReleasesEngineWithoutPreparingIdleHardware() {
        final class InertEngine: AVAudioEngine {
            var preparations = 0
            override func prepare() { preparations += 1 }
            override func stop() {}
        }
        let recorder = Recorder(), token = CaptureToken(UUID().uuidString), engine = InertEngine()
        recorder.token = token; recorder.engine = engine; recorder.keepRecovery = false
        recorder.deviceInfo = ["transport": "builtIn"]
        recorder.stop(token.id)
        recorder.graph.sync {}
        recorder.writer.sync {}
        XCTAssertNil(recorder.engine)
        XCTAssertEqual(engine.preparations, 0)
    }

    func testRetiredGraphCannotAppendToTheSameRecording() throws {
        try withRecording { recorder, token in
            let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                                    channels: 1, interleaved: true))
            let input = try tone(rate: 16000, frames: 1600)
            let conversion = try XCTUnwrap(AVAudioConverter(from: input.format, to: target))
            recorder.captureGeneration = UUID()
            recorder.consume(input, token, target, conversion, generation: UUID())
            XCTAssertEqual(recorder.samples, 0)
            XCTAssertEqual(try recorder.file?.offset(), 0)
        }
    }

    func testFormatReplacementPreservesPreviouslyCapturedPCM() throws {
        try withRecording { recorder, token in
            let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                                    channels: 1, interleaved: true))
            for rate in [48000.0, 16000.0] {
                let generation = UUID()
                recorder.captureGeneration = generation
                let input = try tone(rate: rate, frames: AVAudioFrameCount(rate / 10))
                let conversion = try XCTUnwrap(AVAudioConverter(from: input.format, to: target))
                recorder.converter = conversion
                let before = recorder.samples
                recorder.consume(input, token, target, conversion, generation: generation)
                recorder.flushConverter(token)
                XCTAssertGreaterThanOrEqual(recorder.samples - before, 1500)
                XCTAssertLessThanOrEqual(recorder.samples - before, 1700)
            }
            XCTAssertEqual(try recorder.file?.offset(), UInt64(recorder.samples * 2))
            XCTAssertTrue(recorder.heardSignal)
        }
    }

    func testPreviousSessionCannotAppendToANewRecording() throws {
        try withRecording { recorder, _ in
            let previous = CaptureToken(UUID().uuidString)
            let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                                    channels: 1, interleaved: true))
            let input = try tone(rate: 16000, frames: 1600)
            let conversion = try XCTUnwrap(AVAudioConverter(from: input.format, to: target))
            let generation = UUID()
            recorder.captureGeneration = generation
            recorder.consume(input, previous, target, conversion, generation: generation)
            XCTAssertEqual(recorder.samples, 0)
        }
    }

    func testGraphRetirementPreservesAudioAndResetsReadiness() throws {
        try withRecording { recorder, token in
            let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                                    channels: 1, interleaved: true))
            let input = try tone(rate: 16000, frames: 1600)
            let conversion = try XCTUnwrap(AVAudioConverter(from: input.format, to: target))
            let generation = UUID()
            recorder.captureGeneration = generation; recorder.converter = conversion
            recorder.consume(input, token, target, conversion, generation: generation)
            XCTAssertTrue(recorder.graphHeardSignal)
            recorder.releaseEngine(token)
            XCTAssertTrue(recorder.heardSignal)
            XCTAssertFalse(recorder.graphHeardSignal)
            XCTAssertNil(recorder.captureGeneration)
            XCTAssertGreaterThanOrEqual(recorder.samples, 1600)
        }
    }

    private func tone(rate: Double, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                               channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(frames) { samples[i] = 0.2 * sin(Float(i) * 2 * .pi * 440 / Float(rate)) }
        return buffer
    }

    private func withRecording(_ run: (Recorder, CaptureToken) throws -> Void) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: path.path, contents: nil))
        let file = try FileHandle(forWritingTo: path)
        defer { try? file.close(); try? FileManager.default.removeItem(at: path) }
        let recorder = Recorder(), token = CaptureToken(UUID().uuidString)
        recorder.file = file; recorder.recovery = Recovery(id: token.id); recorder.keepRecovery = false
        recorder.graphStartedAt = DispatchTime.now().uptimeNanoseconds
        try run(recorder, token)
    }
}
