// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VolumeKnob",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VolumeKnob",
            path: "Sources/VolumeKnob"
        )
    ]
)
