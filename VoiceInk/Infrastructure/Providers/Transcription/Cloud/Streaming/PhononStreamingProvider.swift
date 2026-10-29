import Foundation

/// Live preview only: always transcribe the saved recording after stopping.
/// A failed, incomplete, or dropped stream must not become the delivered transcript.
/// Uses the Phonon-compatible PCM/JSON protocol; other WebSocket protocols need adapters.
final class PhononStreamingProvider: StreamingTranscriptionProvider {
    var stopDisposition: StreamingStopDisposition { .useBatchFallback }
    let transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>
    private let connection: PhononStreamingConnection

    init() {
        let events = AsyncStream.makeStream(
            of: StreamingTranscriptionEvent.self, bufferingPolicy: .bufferingNewest(32)
        )
        transcriptionEvents = events.stream
        connection = PhononStreamingConnection(events: events.continuation)
    }

    deinit {
        let connection = connection
        Task { await connection.disconnect() }
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        guard let model = model as? CustomCloudModel, model.streamingProtocol == .phonon, let url = model.streamingURL else {
            throw StreamingTranscriptionError.connectionFailed("Select Phonon live preview for a compatible local transcription endpoint.")
        }
        try await connection.connect(url: url, apiKey: model.apiKey)
    }

    func sendAudioChunk(_ data: Data) async throws {
        try await connection.sendAudioChunk(data)
    }

    func commit() async throws {
        try await connection.commit()
    }

    func disconnect() async {
        await connection.disconnect()
    }
}
