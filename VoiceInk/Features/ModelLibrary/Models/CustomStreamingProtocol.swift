import Foundation

/// Wire protocol used by a custom server, independent of its served model name.
enum CustomStreamingProtocol: String, Codable, CaseIterable, Identifiable {
    case disabled
    case phonon

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .disabled: String(localized: "Off")
        case .phonon: "Phonon"
        }
    }

    static func available(for endpoint: String) -> [Self] {
        allCases.filter {
            $0 == .disabled || CustomStreamingProviderRegistry.endpoint(for: endpoint, protocol: $0) != nil
        }
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        // A model saved with an unavailable adapter can still use batch transcription.
        self = Self(rawValue: value) ?? .disabled
    }
}
