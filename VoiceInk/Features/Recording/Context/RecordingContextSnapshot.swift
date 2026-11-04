import AppKit
import Foundation

struct RecordingContextSnapshot {
    var capturedAt = Date()
    var selectedText: String?
    var clipboardText: String?
    var screenText: String?
}

@MainActor
final class RecordingContextSnapshotStore {
    private(set) var snapshot = RecordingContextSnapshot()
    let vocabularyPreparation: RecordingVocabularyPreparation

    init(savedVocabulary: RecordingVocabulary) {
        vocabularyPreparation = RecordingVocabularyPreparation(savedVocabulary: savedVocabulary)
    }

    func updateSelectedText(_ text: String?) {
        snapshot.selectedText = Self.normalized(text)
    }

    func updateClipboardText(_ text: String?) {
        snapshot.clipboardText = Self.normalized(text)
    }

    func updateScreenText(_ text: String?) {
        snapshot.screenText = Self.normalized(text)
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Which context sources a recording should capture. Context is consumed only by AI
/// enhancement, so each source is needed only when enhancement will run with it enabled.
struct RecordingContextNeeds: Equatable {
    var selectedText: Bool
    var screenCapture: Bool

    static let none = RecordingContextNeeds(selectedText: false, screenCapture: false)

    /// Combines the enhancement configurations that could apply to this recording: the
    /// current mode and any mode a trigger word may switch to after transcription.
    static func required(by configurations: [EnhancementRuntimeConfiguration]) -> RecordingContextNeeds {
        configurations.filter(\.isEnabled).reduce(.none) { needs, configuration in
            RecordingContextNeeds(
                selectedText: needs.selectedText || configuration.useSelectedTextContext,
                screenCapture: needs.screenCapture || configuration.useScreenCaptureContext
            )
        }
    }
}

@MainActor
enum RecordingContextCaptureService {
    static func startCapture(
        into store: RecordingContextSnapshotStore,
        language: String?,
        needs: RecordingContextNeeds
    ) -> [Task<Void, Never>] {
        var tasks: [Task<Void, Never>] = []
        if needs.selectedText {
            tasks.append(Task { @MainActor in
                guard !Task.isCancelled else { return }
                let selectedText = await SelectedTextService.fetchSelectedText()
                guard !Task.isCancelled else { return }
                store.updateSelectedText(selectedText)
            })
        }
        if needs.screenCapture {
            tasks.append(Task { @MainActor in
                guard CGPreflightScreenCaptureAccess(), !Task.isCancelled else { return }
                let screenCaptureService = ScreenCaptureService()
                let screenText = await screenCaptureService.captureAndExtractText()
                guard !Task.isCancelled else { return }
                store.updateScreenText(screenText)
                if let text = store.snapshot.screenText {
                    store.vocabularyPreparation.prepareScreenNames(in: text, language: language)
                }
            })
        }
        return tasks
    }
}
