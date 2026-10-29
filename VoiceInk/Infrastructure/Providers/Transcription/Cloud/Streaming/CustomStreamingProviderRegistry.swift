import Foundation

/// Register custom adapters here; the editor and recording flow stay protocol-independent.
enum CustomStreamingProviderRegistry {
    static func endpoint(for endpoint: String, protocol streamingProtocol: CustomStreamingProtocol) -> URL? {
        switch streamingProtocol {
        case .disabled: nil
        case .phonon: PhononStreamingEndpoint.url(for: endpoint)
        }
    }

    static func makeProvider(for model: CustomCloudModel) -> StreamingTranscriptionProvider? {
        guard model.streamingURL != nil else { return nil }
        switch model.streamingProtocol {
        case .disabled: return nil
        case .phonon: return PhononStreamingProvider()
        }
    }
}
