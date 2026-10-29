#!/usr/bin/env python3
"""Test real custom streaming adapters and session sources without building or launching the app."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import wave

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--live-endpoint", help="Optional separate compatible local transcription endpoint")
parser.add_argument("--audio", type=Path, help="16 kHz mono signed 16-bit PCM WAV for the live test")
args = parser.parse_args()
if bool(args.live_endpoint) != bool(args.audio):
    parser.error("--live-endpoint and --audio must be supplied together")

root = Path(__file__).resolve().parent.parent
support = root / "Tests/CustomStreaming"
staging = root / ".build/custom-streaming-tests"
source_dir = staging / "Sources"
test_dir = staging / "Tests"
source_dir.mkdir(parents=True, exist_ok=True)
test_dir.mkdir(parents=True, exist_ok=True)
sources = [
    "Features/ModelLibrary/Models/TranscriptionModel.swift",
    "Features/ModelLibrary/Models/CustomStreamingProtocol.swift",
    "Features/Recording/Streaming/StreamingTranscriptionService.swift",
    "Features/Recording/Workflows/TranscriptionService.swift",
    "Features/Recording/Workflows/TranscriptionSession.swift",
    "Infrastructure/Providers/Transcription/Contracts/StreamingTranscriptionProvider.swift",
    "Infrastructure/Providers/Transcription/Cloud/Streaming/CustomStreamingProviderRegistry.swift",
    "Infrastructure/Providers/Transcription/Cloud/Streaming/PhononStreamingEndpoint.swift",
    "Infrastructure/Providers/Transcription/Cloud/Streaming/PhononStreamingProvider.swift",
    "Infrastructure/Providers/Transcription/Cloud/Streaming/PhononStreamingConnection.swift",
]
for source in sources:
    shutil.copy2(root / "VoiceInk" / source, source_dir / Path(source).name)
shutil.copy2(support / "AppServiceStubs.swift", source_dir)
shutil.copy2(support / "Package.swift", staging)
shutil.copy2(support / "CustomStreamingTests.swift", test_dir)
server_log = staging / "mock-server.log"
test_log = staging / "test.log"
with server_log.open("w") as errors:
    server = subprocess.Popen([sys.executable, str(support / "mock_server.py")], stdout=subprocess.PIPE, stderr=errors, text=True)
    try:
        port = server.stdout.readline().strip()
        if not port.isdecimal():
            raise RuntimeError(f"Mock server failed; see {server_log}")
        environment = dict(os.environ, CUSTOM_STREAMING_TEST_PORT=port)
        if args.audio:
            with wave.open(str(args.audio)) as audio:
                if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, 16_000):
                    raise ValueError("Live test audio must be 16 kHz mono signed 16-bit PCM WAV")
                pcm = staging / "live-audio.pcm"
                pcm.write_bytes(audio.readframes(audio.getnframes()))
            environment.update(CUSTOM_STREAMING_LIVE_ENDPOINT=args.live_endpoint, CUSTOM_STREAMING_LIVE_PCM=str(pcm))
        with test_log.open("w") as output:
            result = subprocess.run(["swift", "test", "--package-path", str(staging)], env=environment,
                                    stdout=output, stderr=subprocess.STDOUT, timeout=180)
        for line in test_log.read_text().splitlines():
            if any(word in line for word in ["error:", "warning:", "Test Suite", "Executed ", "failed", "passed", "Live compatible server:"]):
                print(line[:500])
        print(f"Full log: {test_log}")
        sys.exit(result.returncode)
    finally:
        server.terminate()
        server.wait(timeout=5)
