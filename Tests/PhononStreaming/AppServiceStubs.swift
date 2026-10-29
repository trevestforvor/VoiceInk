import Foundation

// Test doubles for app services unrelated to Phonon. The model, streaming
// service, session, provider, socket, and transcription contracts are real sources.
final class APIKeyManager {
    static let shared = APIKeyManager()
    func getCustomModelAPIKey(forModelId id: UUID) -> String? { "local" }
    func saveCustomModelAPIKey(_ key: String, forModelId id: UUID) {}
}

enum LanguageDictionary {
    static func forProvider(isMultilingual: Bool, provider: ModelProvider? = nil) -> [String: String] {
        ["en": "English"]
    }
}

struct RecordingVocabulary {
    let terms: [String]
    init(savedTerms: [String] = []) { terms = savedTerms }
}

enum WhisperPrompt {
    static func resolvedPrompt(for language: String) -> String? { nil }
}

struct TranscriptionRuntimeConfiguration {
    let model: any TranscriptionModel
    let requestContext: TranscriptionRequestContext
}

enum VoiceInkEngineError: Error { case transcriptionFailed }
final class FluidAudioTranscriptionService {}
enum FluidAudioModelManager {
    static func isNemotronModel(named name: String) -> Bool { false }
    static func isParakeetUnifiedModel(named name: String) -> Bool { false }
}
enum CloudProviderRegistry {
    static func provider(for provider: ModelProvider) -> UnusedCloudProvider? { nil }
}
struct UnusedCloudProvider {
    let isStreamingOnly = false
    func makeStreamingProvider(vocabulary: RecordingVocabulary) -> StreamingTranscriptionProvider? { nil }
}
class UnusedStreamingProvider: StreamingTranscriptionProvider {
    let transcriptionEvents = AsyncStream<StreamingTranscriptionEvent> { $0.finish() }
    init(fluidAudioService: FluidAudioTranscriptionService? = nil) {}
    func connect(model: any TranscriptionModel, language: String?) async throws {}
    func sendAudioChunk(_ data: Data) async throws {}
    func commit() async throws {}
    func disconnect() async {}
}
final class FluidAudioStreamingProvider: UnusedStreamingProvider {}
final class FluidAudioNemotronStreamingProvider: UnusedStreamingProvider {}
final class FluidAudioUnifiedStreamingProvider: UnusedStreamingProvider {}
