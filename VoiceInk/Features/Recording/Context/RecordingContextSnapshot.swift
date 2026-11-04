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

/// Screen OCR feeds only AI enhancement, so it is needed only when an enhancement that
/// could run for this recording has screen context enabled: the current mode, or a mode a
/// trigger word may switch to after transcription. (Selected text is already fetched only
/// inside the enhancement step, using the resolved mode.)
enum RecordingContextNeeds {
    static func screenCapture(for configurations: [EnhancementRuntimeConfiguration]) -> Bool {
        configurations.contains { $0.isEnabled && $0.useScreenCaptureContext }
    }
}

@MainActor
enum RecordingContextCaptureService {
    static func startCapture(
        into store: RecordingContextSnapshotStore,
        language: String?,
        captureScreen: Bool
    ) -> [Task<Void, Never>] {
        guard captureScreen else { return [] }
        let screenCapture = Task { @MainActor in
            guard CGPreflightScreenCaptureAccess(), !Task.isCancelled else { return }
            let screenCaptureService = ScreenCaptureService()
            let screenText = await screenCaptureService.captureAndExtractText()
            guard !Task.isCancelled else { return }
            store.updateScreenText(screenText)
            if let text = store.snapshot.screenText {
                store.vocabularyPreparation.prepareScreenNames(in: text, language: language)
            }
        }
        return [screenCapture]
    }
}
