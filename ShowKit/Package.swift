// swift-tools-version: 5.9

// The engine behind Show Deck: a common control model, the wire encodings
// (OSC, MIDI, text lines, Art-Net), network transports and one driver per
// console family. No UI here, so it can be unit-tested with `swift test` on a Mac.

import PackageDescription

let package = Package(
    name: "ShowKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "ShowKit", targets: ["ShowKit"])
    ],
    targets: [
        .target(name: "ShowKit"),
        .testTarget(name: "ShowKitTests", dependencies: ["ShowKit"])
    ]
)
