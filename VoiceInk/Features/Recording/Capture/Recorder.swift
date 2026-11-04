import AVFoundation
import Combine
import CoreAudio
import Foundation
import os

@MainActor
class Recorder: NSObject, ObservableObject {
    var recorder: CoreAudioRecorder?
    let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "Recorder")
    let deviceManager = AudioDeviceManager.shared
    private var lifecycleCancellable: AnyCancellable?
    var recordingDeviceChangeObserver: NSObjectProtocol?
    var recordingDeviceNotificationTask: Task<Void, Never>?
    private let mediaController = MediaController.shared
    private let playbackController = PlaybackController.shared
    /// Dedicated serial queue for hardware setup.
    let audioSetupQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.audioSetup", qos: .userInitiated)
    private let recordingAudioActionDelayNanoseconds: UInt64 = 220_000_000
    private var audioMuteTask: Task<Void, Never>?
    private var mediaPauseTask: Task<Void, Never>?
    private var audioRestorationTask: Task<Void, Never>?
    private var playbackSessionID: UUID?
    private let smoothedValuesLock = NSLock()
    private var smoothedAverage: Float = 0
    private var smoothedPeak: Float = 0
    /// Hardware started by `prestartHardware`, awaiting adoption by `startRecording`.
    private var prestart: Prestart?

    private struct Prestart {
        let url: URL
        let deviceID: AudioDeviceID
        let outcome: PrestartOutcome
    }

    /// Written on `audioSetupQueue`; read only after a barrier on that serial queue.
    private final class PrestartOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var storedError: Error?
        var error: Error? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storedError
            }
            set {
                lock.lock()
                storedError = newValue
                lock.unlock()
            }
        }
    }

    /// Audio chunk callback for streaming. Can be updated while recording;
    /// changes are forwarded to the live CoreAudioRecorder.
    var onAudioChunk: ((_ data: Data) -> Void)? {
        didSet { recorder?.onAudioChunk = onAudioChunk }
    }

    enum RecorderError: Error {
        case couldNotStartRecording
        case noUsableMicrophone(internalMicrophoneBlockedByClosedLid: Bool)
        case audioSystemNotRunning
    }

    override init() {
        super.init()
        lifecycleCancellable = LifecycleObserver.shared.publisher(
            for: [.audioDeviceChanged, .systemWillSleep, .systemDidWake]
        ).sink { [weak self] _ in
            Task { @MainActor in
                self?.invalidatePreparedAudioUnit()
            }
        }
        setupRecordingDeviceChangeObserver()
        schedulePrepareForCurrentDevice(reason: "init")
    }

    /// Starts capture hardware without waiting, dispatching straight to the setup queue so
    /// it does not wait behind main-actor work such as building the recorder panel.
    /// `startRecording(toOutputFile:)` with the same URL adopts it; otherwise call
    /// `discardPrestartedHardware(at:)`. Returns false if no microphone is usable.
    @discardableResult
    func prestartHardware(toOutputFile url: URL) -> Bool {
        guard prestart == nil, let deviceID = deviceManager.resolveCurrentRecordingDevice().deviceID else {
            return false
        }
        deviceManager.beginRecordingSetup(deviceID: deviceID)

        let coreAudioRecorder = recorder ?? CoreAudioRecorder()
        coreAudioRecorder.onAudioChunk = onAudioChunk
        recorder = coreAudioRecorder

        let selectedChannels = deviceManager.selectedInputChannels(for: deviceID)
        let outcome = PrestartOutcome()
        let requestedAt = DispatchTime.now().uptimeNanoseconds
        audioSetupQueue.async { [logger] in
            do {
                try coreAudioRecorder.startRecording(
                    toOutputFile: url, deviceID: deviceID, selectedInputChannels: selectedChannels
                )
                let elapsedMs = (DispatchTime.now().uptimeNanoseconds - requestedAt) / 1_000_000
                logger.notice("Prestarted recording hardware running elapsedMs=\(elapsedMs, privacy: .public)")
            } catch {
                outcome.error = error
            }
        }
        prestart = Prestart(url: url, deviceID: deviceID, outcome: outcome)
        return true
    }

    /// Stops hardware started by `prestartHardware` that no recording adopted, and removes
    /// its file. A no-op once adopted or already discarded.
    func discardPrestartedHardware(at url: URL, clearAudioChunk: Bool = true) async {
        guard let pending = prestart, pending.url == url else { return }
        prestart = nil
        let currentRecorder = recorder
        await withCheckedContinuation { continuation in
            audioSetupQueue.async {
                currentRecorder?.stopRecording()
                continuation.resume()
            }
        }
        if clearAudioChunk {
            onAudioChunk = nil
        }
        try? FileManager.default.removeItem(at: url)
        // Prestarts happen only while idle, so no other recording owns the device session.
        deviceManager.recordingDidStop()
    }

    /// Waits for a pending prestart for `url` and reports whether its hardware is running.
    private func adoptPrestartedHardware(for url: URL) async -> AudioDeviceID? {
        guard let pending = prestart else { return nil }
        prestart = nil
        guard pending.url == url else {
            // Not ours: release it so this recording starts cleanly, keeping the audio
            // callback the caller installed for this recording.
            prestart = pending
            await discardPrestartedHardware(at: pending.url, clearAudioChunk: false)
            return nil
        }
        // The serial setup queue runs the prestart before this barrier.
        await withCheckedContinuation { continuation in
            audioSetupQueue.async { continuation.resume() }
        }
        if let error = pending.outcome.error {
            logger.warning(
                "Prestarted recording failed; starting normally error=\(error, privacy: .public)"
            )
            return nil
        }
        return pending.deviceID
    }

    func startRecording(toOutputFile url: URL) async throws {
        let prestartedDeviceID = await adoptPrestartedHardware(for: url)
        var deviceID: AudioDeviceID
        if let prestartedDeviceID {
            deviceID = prestartedDeviceID
        } else {
            let resolution = deviceManager.resolveCurrentRecordingDevice()
            guard let resolvedDeviceID = resolution.deviceID else {
                onAudioChunk = nil
                throw RecorderError.noUsableMicrophone(
                    internalMicrophoneBlockedByClosedLid: resolution.internalMicrophoneBlockedByClosedLid
                )
            }
            deviceID = resolvedDeviceID
        }

        deviceManager.beginRecordingSetup(deviceID: deviceID)

        let playbackSessionID = playbackController.beginRecordingSession()
        self.playbackSessionID = playbackSessionID
        mediaController.beginRecordingSession(sessionID: playbackSessionID)
        audioRestorationTask?.cancel()
        audioRestorationTask = nil
        pauseMedia(sessionID: playbackSessionID)
        muteSystemAudio(sessionID: playbackSessionID)

        let coreAudioRecorder = recorder ?? CoreAudioRecorder()
        coreAudioRecorder.onAudioChunk = onAudioChunk
        recorder = coreAudioRecorder

        do {
            do {
                if prestartedDeviceID == nil {
                    try await startHardwareRecording(coreAudioRecorder, to: url, deviceID: deviceID)
                }
            } catch {
                let retryResolution = deviceManager.resolveCurrentRecordingDevice(excluding: deviceID)
                guard deviceManager.isClamshellClosed,
                    deviceManager.isInternalMicrophone(deviceID),
                    let fallbackDeviceID = retryResolution.deviceID
                else {
                    throw error
                }

                deviceID = fallbackDeviceID
                deviceManager.beginRecordingSetup(deviceID: fallbackDeviceID)
                try await startHardwareRecording(coreAudioRecorder, to: url, deviceID: fallbackDeviceID)
            }

            deviceManager.recordingDidStart(deviceID: deviceID)
            showRecordingDeviceNotification(for: deviceID)
            resetAudioMeter()
        } catch {
            logger.error(
                "Failed to start recording deviceID=\(deviceID, privacy: .public) file=\(url.lastPathComponent, privacy: .public) error=\(error, privacy: .public)"
            )
            await stopRecording()
            if (error as? CoreAudioRecorderError)?.status == kAudioHardwareNotRunningError {
                throw RecorderError.audioSystemNotRunning
            }
            throw RecorderError.couldNotStartRecording
        }
    }

    func stopRecording() async {
        // Stopping the current recorder below also stops unadopted prestarted hardware.
        prestart = nil
        recordingDeviceNotificationTask?.cancel()
        recordingDeviceNotificationTask = nil
        let playbackSessionID = self.playbackSessionID
        audioMuteTask?.cancel()
        audioMuteTask = nil
        mediaPauseTask?.cancel()
        mediaPauseTask = nil
        // Capture current recorder to stop it on the serial hardware queue.
        let currentRecorder = self.recorder

        await withCheckedContinuation { continuation in
            audioSetupQueue.async {
                currentRecorder?.stopRecording()
                continuation.resume()
            }
        }
        guard self.playbackSessionID == playbackSessionID else { return }
        onAudioChunk = nil

        resetAudioMeter()

        audioRestorationTask?.cancel()
        audioRestorationTask = Task {
            if let playbackSessionID {
                await mediaController.unmuteSystemAudio(sessionID: playbackSessionID)
                await playbackController.resumeMedia(sessionID: playbackSessionID)
            }
        }
        deviceManager.recordingDidStop()
    }

    private func muteSystemAudio(sessionID: UUID) {
        audioMuteTask?.cancel()
        audioMuteTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.recordingAudioActionDelayNanoseconds)
            guard !Task.isCancelled else { return }
            _ = self.mediaController.muteSystemAudio(sessionID: sessionID)
        }
    }

    private func pauseMedia(sessionID: UUID) {
        mediaPauseTask?.cancel()
        mediaPauseTask = Task { [weak self] in
            guard let self else { return }
            await self.playbackController.pauseMedia(sessionID: sessionID)
        }
    }

    private func schedulePrepareForCurrentDevice(reason: String) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return
        }

        let deviceID = deviceManager.getCurrentDevice()
        guard deviceID != 0 else {
            recorder?.teardown()
            return
        }

        let coreAudioRecorder = recorder ?? CoreAudioRecorder()
        coreAudioRecorder.onAudioChunk = onAudioChunk
        recorder = coreAudioRecorder

        let selectedChannels = deviceManager.selectedInputChannels(for: deviceID)
        audioSetupQueue.async { [logger] in
            do {
                try coreAudioRecorder.prepare(deviceID: deviceID, selectedInputChannels: selectedChannels)
            } catch {
                logger.warning(
                    "Recorder prepare failed reason=\(reason, privacy: .public) deviceID=\(deviceID, privacy: .public) error=\(error, privacy: .public)"
                )
            }
        }
    }

    private func invalidatePreparedAudioUnit() {
        guard let coreAudioRecorder = recorder else { return }
        audioSetupQueue.async {
            coreAudioRecorder.invalidatePreparation()
        }
    }

    func audioMeterSnapshot() -> AudioMeter {
        guard let recorder else {
            return AudioMeter(averagePower: 0, peakPower: 0)
        }

        // Sample audio levels (thread-safe read)
        let averagePower = recorder.averagePower
        let peakPower = recorder.peakPower

        // Normalize values
        let minVisibleDb: Float = -60.0
        let maxVisibleDb: Float = 0.0

        let normalizedAverage: Float
        if averagePower < minVisibleDb {
            normalizedAverage = 0.0
        } else if averagePower >= maxVisibleDb {
            normalizedAverage = 1.0
        } else {
            normalizedAverage = (averagePower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        let normalizedPeak: Float
        if peakPower < minVisibleDb {
            normalizedPeak = 0.0
        } else if peakPower >= maxVisibleDb {
            normalizedPeak = 1.0
        } else {
            normalizedPeak = (peakPower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        // Apply EMA smoothing with thread-safe access
        smoothedValuesLock.lock()
        smoothedAverage = smoothedAverage * 0.6 + normalizedAverage * 0.4
        smoothedPeak = smoothedPeak * 0.6 + normalizedPeak * 0.4
        let audioMeter = AudioMeter(
            averagePower: Double(smoothedAverage),
            peakPower: Double(smoothedPeak)
        )
        smoothedValuesLock.unlock()

        return audioMeter
    }

    private func resetAudioMeter() {
        smoothedValuesLock.lock()
        smoothedAverage = 0
        smoothedPeak = 0
        smoothedValuesLock.unlock()
    }

    // MARK: - Cleanup

    deinit {
        recordingDeviceNotificationTask?.cancel()
        audioMuteTask?.cancel()
        mediaPauseTask?.cancel()
        audioRestorationTask?.cancel()
        if let observer = recordingDeviceChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        recorder?.teardown()
    }
}

struct AudioMeter: Equatable {
    let averagePower: Double
    let peakPower: Double
}
