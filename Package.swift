// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "apple-reminders-calendar-mcp",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "apple-reminders-calendar-mcp", targets: ["RemindersMCP"])],
    targets: [
        // Thin Objective-C bridge to Apple's private ReminderKit — only for what EventKit can't write
        // (real tags, flags). Everything else goes through public EventKit.
        .target(
            name: "ReminderKitBridge",
            cSettings: [.unsafeFlags(["-fobjc-arc", "-F/System/Library/PrivateFrameworks"])],
            linkerSettings: [.unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "ReminderKit"])]
        ),
        .executableTarget(
            name: "RemindersMCP",
            dependencies: ["ReminderKitBridge"],
            exclude: ["Support"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", "Sources/RemindersMCP/Support/Info.plist"]),
            ]
        ),
        // Black-box end-to-end tests against your real Reminders/Calendar (temporary lists, cleaned up): `swift run e2e`
        .executableTarget(name: "e2e", dependencies: ["ReminderKitBridge"], path: "E2E", swiftSettings: [.swiftLanguageMode(.v5)],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                                         "-Xlinker", "Sources/RemindersMCP/Support/Info.plist"])]),
        .testTarget(name: "RemindersMCPTests", dependencies: ["RemindersMCP"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
