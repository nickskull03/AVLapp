// swift-tools-version: 5.9

// An app package: open this folder in Xcode, pick an iPhone or iPad, and run.
// The engine (protocols, drivers, the control model) is the ShowKit package
// next to it, which has the unit tests.

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "Show Deck",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .iOSApplication(
            name: "Show Deck",
            targets: ["AppModule"],
            bundleIdentifier: "com.lighting.showdeck",
            teamIdentifier: "",
            displayVersion: "0.1",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .lightbulb),
            accentColor: .presetColor(.orange),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ],
            capabilities: [
                .localNetwork(purposeString: "Show Deck talks to your lighting console and mixer on the local network.")
            ],
            appCategory: .music
        )
    ],
    dependencies: [
        .package(path: "../ShowKit")
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            dependencies: [
                .product(name: "ShowKit", package: "ShowKit")
            ],
            path: "."
        )
    ]
)
