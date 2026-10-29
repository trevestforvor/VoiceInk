import Foundation
import XCTest
@testable import VoiceInkStreaming

final class PhononStreamingTests: XCTestCase {
    private func model(path: String = "happy", enabled: Bool = true) -> CustomCloudModel {
        let port = ProcessInfo.processInfo.environment["PHONON_TEST_PORT"] ?? "0"
        return CustomCloudModel(
            name: "phonon-local", displayName: "Phonon", description: "Test",
            apiEndpoint: "http://127.0.0.1:\(port)/\(path)/v1/audio/transcriptions",
            modelName: "phonon-2", isMultilingual: false, usePhononStreaming: enabled
        )
    }

    func testLoopbackEndpointDerivation() {
        let cases = [
            "http://127.0.0.1:9877/v1/audio/transcriptions": "ws://127.0.0.1:9877/v1/audio/stream",
            "https://localhost:9877/proxy/v1/audio/transcriptions": "wss://localhost:9877/proxy/v1/audio/stream",
            "http://[::1]:9877/v1/audio/transcriptions": "ws://[::1]:9877/v1/audio/stream"
        ]
        for (input, expected) in cases {
            XCTAssertEqual(PhononStreamingEndpoint.url(for: input)?.absoluteString, expected)
        }
    }

    func testRejectsRemoteAndAmbiguousEndpointsEvenWhenOptedIn() {
        for endpoint in [
            "https://api.example.com/v1/audio/transcriptions",
            "http://192.168.1.2/v1/audio/transcriptions",
            "http://localhost.evil.example/v1/audio/transcriptions",
            "http://localhost@evil.example/v1/audio/transcriptions",
            "http://user:secret@localhost/v1/audio/transcriptions",
            "http://127.0.0.1:70000/v1/audio/transcriptions",
            "ftp://localhost/v1/audio/transcriptions",
            "http://localhost/v1/chat/completions",
            "http://localhost/v1/audio/transcriptions?key=secret",
            "http://localhost/v1/audio/transcriptions#fragment"
        ] {
            XCTAssertNil(PhononStreamingEndpoint.url(for: endpoint), endpoint)
            let remote = CustomCloudModel(
                name: "custom", displayName: "Custom", description: "Test", apiEndpoint: endpoint,
                modelName: "phonon-2", usePhononStreaming: true
            )
            XCTAssertFalse(remote.supportsStreaming, endpoint)
        }
    }

    func testLegacyModelsStayBatchOnlyAndOptInPersists() throws {
        XCTAssertFalse(model(enabled: false).supportsStreaming)
        let original = model()
        let encoded = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(CustomCloudModel.self, from: encoded)
        XCTAssertTrue(restored.usePhononStreaming)
        XCTAssertEqual(restored.phononStreamingURL, original.phononStreamingURL)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "usePhononStreaming")
        let decoded = try JSONDecoder().decode(CustomCloudModel.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertFalse(decoded.usePhononStreaming)
        XCTAssertFalse(decoded.supportsStreaming)
    }

    func testProviderAlwaysRequestsBatchFinalization() {
        let provider = PhononStreamingProvider()
        if case .useBatchFallback = provider.stopDisposition {} else {
            XCTFail("Preview text must never become the delivered transcript")
        }
        XCTAssertNil(provider.finalizationEvents)
    }

    func testSnapshotsPreserveRepeatedPhrasesAndDone() async throws {
        let provider = PhononStreamingProvider()
        let collector = Task { () -> [String] in
            var snapshots: [String] = []
            for await event in provider.transcriptionEvents {
                switch event {
                case .partial(let text): snapshots.append(text)
                case .error(let error): XCTFail("Unexpected socket error: \(error)")
                default: break
                }
            }
            return snapshots
        }
        try await provider.connect(model: model(), language: "en")
        try await provider.sendAudioChunk(Data(repeating: 0, count: 640))
        try await provider.commit()
        let snapshots = await collector.value
        XCTAssertTrue(snapshots.contains("hello hello"))
        XCTAssertEqual(snapshots.last, "hello hello world")
        await provider.disconnect()
    }

    func testMalformedAndErrorFramesClosePreview() async throws {
        for path in ["malformed", "missing-text", "server-error", "abrupt"] {
            let provider = PhononStreamingProvider()
            let collector = Task { () -> Int in
                var errors = 0
                for await event in provider.transcriptionEvents {
                    if case .error = event { errors += 1 }
                }
                return errors
            }
            try await provider.connect(model: model(path: path), language: nil)
            let errors = await collector.value
            XCTAssertEqual(errors, 1, path)
            await provider.disconnect()
        }
    }

    func testCancellationBeforeAndDuringConnect() async throws {
        let cancelled = PhononStreamingProvider()
        await cancelled.disconnect()
        do {
            try await cancelled.connect(model: model(), language: nil)
            XCTFail("A cancelled provider must not reconnect")
        } catch is CancellationError {}

        let connecting = PhononStreamingProvider()
        let task = Task { try await connecting.connect(model: model(path: "slow"), language: nil) }
        try await Task.sleep(for: .milliseconds(50))
        await connecting.disconnect()
        do {
            try await task.value
            XCTFail("An in-flight connect must not revive after cancellation")
        } catch {}
        var latePreviews = 0
        for await event in connecting.transcriptionEvents {
            if case .partial = event { latePreviews += 1 }
        }
        XCTAssertEqual(latePreviews, 0)
    }

    func testReleasingProviderClosesItsPreviewStream() async throws {
        var provider: PhononStreamingProvider? = PhononStreamingProvider()
        let events = try XCTUnwrap(provider?.transcriptionEvents)
        let collector = Task {
            for await _ in events {}
        }
        try await provider?.connect(model: model(), language: nil)
        provider = nil
        await collector.value
    }

    func testLivePhononServerWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["PHONON_LIVE_ENDPOINT"],
            let pcmPath = environment["PHONON_LIVE_PCM"]
        else { throw XCTSkip("Pass --live-endpoint and --audio to run against a separate Phonon server") }
        let liveModel = CustomCloudModel(
            name: "phonon-live-test", displayName: "Phonon test", description: "Test",
            apiEndpoint: endpoint, modelName: "phonon-2", isMultilingual: false, usePhononStreaming: true
        )
        let provider = PhononStreamingProvider()
        let collector = Task { () -> (Int, Int, String) in
            var partials = 0
            var errors = 0
            var last = ""
            for await event in provider.transcriptionEvents {
                switch event {
                case .partial(let text): partials += 1; last = text
                case .error: errors += 1
                default: break
                }
            }
            return (partials, errors, last)
        }
        try await provider.connect(model: liveModel, language: "en")
        let audio = try Data(contentsOf: URL(fileURLWithPath: pcmPath))
        for offset in stride(from: 0, to: audio.count, by: 6_400) {
            try await provider.sendAudioChunk(audio.subdata(in: offset..<min(offset + 6_400, audio.count)))
            try await Task.sleep(for: .milliseconds(200))
        }
        try await provider.commit()
        let result = await collector.value
        XCTAssertGreaterThan(result.0, 1)
        XCTAssertEqual(result.1, 0)
        XCTAssertFalse(result.2.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        print("Live Phonon: \(result.0) preview updates, \(result.1) errors, final preview: \(result.2)")
        await provider.disconnect()
    }

    @MainActor
    func testSessionUsesCompleteRecordingAfterHealthyAndFailedPreview() async throws {
        for path in ["happy", "server-error", "reject"] {
            let fallback = BatchSpy()
            var snapshots: [String] = []
            let service = StreamingTranscriptionService(onPartialTranscript: { snapshots.append($0) })
            let session = StreamingTranscriptionSession(streamingService: service, fallbackService: fallback)
            let callback = try await session.prepare(
                configuration: TranscriptionRuntimeConfiguration(
                    model: model(path: path), requestContext: TranscriptionRequestContext(language: "en", prompt: nil)
                ), vocabulary: RecordingVocabulary()
            )
            callback?(Data(repeating: 0, count: 640))
            // Give the local fixture time to open or fail before stopping.
            for _ in 0..<100 {
                if service.isActive, !snapshots.isEmpty || path != "happy" { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let recording = URL(fileURLWithPath: "/tmp/voiceink-phonon-complete-recording.wav")
            let text = try await session.transcribe(audioURL: recording, vocabulary: RecordingVocabulary())
            XCTAssertEqual(text, "complete recording result", path)
            XCTAssertEqual(fallback.receivedURLs, [recording], path)
            if path == "happy" { XCTAssertFalse(snapshots.isEmpty) }
        }
    }

    @MainActor
    func testCancelledSessionDoesNotUploadRecording() async throws {
        let fallback = BatchSpy()
        let session = StreamingTranscriptionSession(
            streamingService: StreamingTranscriptionService(), fallbackService: fallback
        )
        _ = try await session.prepare(
            configuration: TranscriptionRuntimeConfiguration(
                model: model(path: "slow"), requestContext: TranscriptionRequestContext(language: nil, prompt: nil)
            ), vocabulary: RecordingVocabulary()
        )
        session.cancel()
        do {
            _ = try await session.transcribe(
                audioURL: URL(fileURLWithPath: "/tmp/cancelled.wav"), vocabulary: RecordingVocabulary()
            )
            XCTFail("Cancelled dictation must not deliver text")
        } catch is CancellationError {}
        XCTAssertTrue(fallback.receivedURLs.isEmpty)
    }
}

private final class BatchSpy: TranscriptionService {
    var receivedURLs: [URL] = []
    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws -> String {
        receivedURLs.append(audioURL)
        return "complete recording result"
    }
}
