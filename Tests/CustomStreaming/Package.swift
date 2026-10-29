// swift-tools-version: 6.0
import PackageDescription

// scripts/test-custom-streaming.py stages the actual application sources here.
let package = Package(
    name: "VoiceInkCustomStreamingTests",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "VoiceInkStreaming", path: "Sources"),
        .testTarget(name: "CustomStreamingTests", dependencies: ["VoiceInkStreaming"], path: "Tests")
    ],
    swiftLanguageModes: [.v5]
)
