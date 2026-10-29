import Foundation

/// Serializes socket state while audio arrives from the recording queue.
actor PhononStreamingConnection {
    private let events: AsyncStream<StreamingTranscriptionEvent>.Continuation
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var closing = false
    private var completed = false
    private var committedSegments: [String] = []

    init(events: AsyncStream<StreamingTranscriptionEvent>.Continuation) {
        self.events = events
    }

    func connect(url: URL, apiKey: String) async throws {
        guard !closing, socket == nil else { throw CancellationError() }
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 3_600
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: url)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 1_048_576
        self.session = session
        self.socket = socket
        socket.resume()

        do {
            // The shared recorder already supplies 16 kHz mono, signed 16-bit PCM.
            try await socket.send(.string("{\"sample_rate\":16000,\"format\":\"pcm_s16le\"}"))
            try Task.checkCancellation()
            guard !closing else { throw CancellationError() }
            events.yield(.sessionStarted)
            receiveTask = Task { [weak self] in
                await self?.receiveMessages(from: socket)
            }
        } catch {
            disconnect()
            throw error
        }
    }

    func sendAudioChunk(_ data: Data) async throws {
        guard let socket, !closing, !completed else { throw StreamingTranscriptionError.notConnected }
        do {
            try await socket.send(.data(data))
        } catch {
            fail(error)
            throw error
        }
    }

    func commit() async throws {
        guard let socket, !closing, !completed else { throw StreamingTranscriptionError.notConnected }
        try await socket.send(.string("{\"type\":\"end\"}"))
    }

    func disconnect() {
        closing = true
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        events.finish()
    }

    private struct Message: Decodable {
        let type: String
        let text: String?
        let message: String?
    }

    private func receiveMessages(from socket: URLSessionWebSocketTask) async {
        do {
            while !closing, !completed, !Task.isCancelled {
                let frame = try await socket.receive()
                // disconnect() can run while receive() is suspended. Never publish late text.
                guard !closing, !Task.isCancelled else { return }
                let data: Data
                switch frame {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: continue
                }
                let message = try JSONDecoder().decode(Message.self, from: data)
                switch message.type {
                case "partial", "final", "done":
                    guard let text = message.text else {
                        throw StreamingTranscriptionError.serverError("Phonon returned a transcript without text.")
                    }
                    if message.type == "final" {
                        if !text.isEmpty { committedSegments.append(text) }
                        events.yield(.partial(text: committedSegments.joined(separator: " ")))
                    } else if message.type == "partial" {
                        // Emit full snapshots, so a slow UI can safely skip intermediate previews.
                        let prefix = committedSegments.joined(separator: " ")
                        events.yield(.partial(text: prefix.isEmpty ? text : prefix + " " + text))
                    } else {
                        completed = true
                        events.yield(.partial(text: text))
                        events.finish()
                    }
                case "error":
                    throw StreamingTranscriptionError.serverError(message.message ?? "Phonon streaming failed.")
                default:
                    break
                }
            }
        } catch {
            if !closing, !Task.isCancelled { fail(error) }
        }
    }

    private func fail(_ error: Error) {
        guard !closing, !completed else { return }
        events.yield(.error(error))
        disconnect()
    }
}
