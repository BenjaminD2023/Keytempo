// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Keytempo",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Keytempo", targets: ["Keytempo"]), .executable(name: "TypingBench", targets: ["TypingBench"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "TypingCore"),
        .target(name: "TypingStore", dependencies: ["TypingCore", "CSQLite"]),
        .executableTarget(name: "Keytempo", dependencies: ["TypingCore", "TypingStore"]),
        .executableTarget(name: "TypingBench", dependencies: ["TypingCore", "TypingStore"]),
        .testTarget(name: "TypingCoreTests", dependencies: ["TypingCore"]),
        .testTarget(name: "TypingStoreTests", dependencies: ["TypingStore", "TypingCore", "CSQLite"])
    ],
    swiftLanguageVersions: [.v5]
)
