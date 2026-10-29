# Custom streaming live preview (MVP)

This adds an optional live preview to a compatible custom transcription server. The
completed recording is always transcribed through the existing file endpoint
after stopping. Preview text is never used as the final delivered transcript.

The adapter is model-independent: it does not inspect a model's name or vendor.
It currently implements the Phonon-compatible PCM/JSON WebSocket protocol below.
An OpenAI-compatible file endpoint alone does not imply streaming compatibility;
servers using other WebSocket protocols require their own adapter.

## Supported streaming protocol

- Connect to `/v1/audio/stream` on the same host, port, and optional proxy prefix.
- Send `{"sample_rate":16000,"format":"pcm_s16le"}` as the first text frame.
- Send 16 kHz mono signed 16-bit little-endian PCM in binary frames.
- Receive JSON messages with `type` and `text`: `partial` replaces the current
  segment, `final` commits that segment, and `done` supplies the full transcript.
- A JSON `error` message may contain a `message` describing the failure.
- To finish a stream explicitly, send `{"type":"end"}`. Normal MVP stop behavior
  closes the preview and uses full-recording transcription instead.

## Enable

The initial adapter supports local Phonon servers. Use an existing Fermion Phonon server with `/v1/audio/stream` support, or
start one on an unused port:

```sh
fermion serve phonon-2.5-en --host 127.0.0.1 --port 9878 --served-model-name phonon-2
```

In VoiceInk's custom transcription model editor:

- Set the API endpoint to `http://127.0.0.1:9878/v1/audio/transcriptions`.
- Set the model name to the server's served model name (`phonon-2` in this example).
- Use the server's API key, or `local` as the editor's required placeholder when
  the local server has no authentication configured.
- Set **Live Preview** to **Phonon** and save.
- Select that custom model in the recording mode and enable **Real-time**.

Existing custom models remain batch-only until explicitly opted in. The editor
offers only adapters compatible with the entered endpoint. The initial Phonon
adapter accepts loopback HTTP(S) transcription endpoints. `localhost`,
`127.0.0.1`, and `::1` are supported. Remote servers, URL credentials, query
parameters, and fragments are excluded from this first version. The streaming
URL is derived on the same host and port, preserving an optional proxy path.

## Expected behavior

- The recorder's existing live-text UI displays changing transcript snapshots.
- Preview is best effort. Connection refusal, unsupported streaming, a busy
  server, malformed frames, dropped audio, or a connection loss cannot replace
  the full-recording transcription with a partial result.
- Stopping recording closes the preview connection before the normal file
  transcription request. Final text still waits for that request and the normal
  formatting/enhancement pipeline; this MVP does not reduce finalization latency.
- Cancelling dictation closes the socket without uploading the saved recording.
- Preview may differ from final text. Language hints and vocabulary biasing in
  the streaming protocol are outside this MVP; existing batch behavior is retained.
- No new production dependencies or changes to other providers are included.

## Adding another adapter

The editor and recorder depend on `CustomStreamingProtocol` and
`CustomStreamingProviderRegistry`, rather than a concrete provider.

1. Implement `StreamingTranscriptionProvider` in a separate adapter file, with
   its own transport, wire format, endpoint validation, and cleanup. For the
   preview-only behavior in this MVP, return `.useBatchFallback` at stop.
2. Add its identifier and display name to `CustomStreamingProtocol`.
3. Register its endpoint resolver and provider factory in
   `CustomStreamingProviderRegistry`. Its option appears automatically in the
   editor for supported endpoints; the recording and fallback flow need no edits.

`PhononStreamingProvider`, `PhononStreamingConnection`, and
`PhononStreamingEndpoint` contain the initial protocol-specific implementation.
The selected protocol is persisted separately from the model name. The previous
`usePhononStreaming` setting migrates to the Phonon selection; unknown protocol
identifiers disable streaming while preserving batch transcription.

## Regression tests

On macOS 15+ with Swift and Python 3:

```sh
python3 scripts/test-custom-streaming.py
```

The runner stages the actual model, socket, streaming service, and recording
session sources in an ignored Swift package. Only unrelated app services use
test doubles; tests do not access the app's keychain, install the app, or require
a model download. A loopback WebSocket fixture checks protocol handling and the
session's full-recording fallback. The optional live-server test is skipped.

To also test the adapter against a separate Phonon process, supply its endpoint
and a 16 kHz mono signed 16-bit PCM WAV. This optional test uses `local` as its
placeholder bearer token; use an unauthenticated local test server:

```sh
python3 scripts/test-custom-streaming.py \
  --live-endpoint http://127.0.0.1:9878/v1/audio/transcriptions \
  --audio /path/to/public-test.wav
```

These tests verify transport and recording-session behavior. A full app build
and manual recorder-panel check are separate validation steps.
