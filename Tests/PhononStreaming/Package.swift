// swift-tools-version: 6.0
import PackageDescription

// scripts/test-phonon-streaming.py stages the actual application sources here.
let package = Package(
    name: "VoiceInkPhononStreamingTests",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "VoiceInkStreaming", path: "Sources"),
        .testTarget(name: "PhononStreamingTests", dependencies: ["VoiceInkStreaming"], path: "Tests")
    ],
    swiftLanguageModes: [.v5]
)
