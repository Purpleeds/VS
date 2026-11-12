// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PitchLane",
    platforms: [
        .iOS("26.0"),
    ],
    products: [
        // xtool builds the (single) library product as the app.
        .library(name: "PitchLane", targets: ["PitchLane"]),
    ],
    targets: [
        // Pure Swift, Foundation only. DSP, song model, parsers, scoring, logging, persistence.
        .target(name: "PitchLaneCore"),
        // SwiftUI + AVFoundation app. Every file is wrapped in `#if canImport(SwiftUI)`
        // so `swift test` still builds on Linux/WSL.
        .target(name: "PitchLane", dependencies: ["PitchLaneCore"]),
        .testTarget(name: "PitchLaneCoreTests", dependencies: ["PitchLaneCore"]),
    ]
)
