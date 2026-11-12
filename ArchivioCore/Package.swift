// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArchivioCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ArchivioCore", targets: ["ArchivioCore"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "ArchivioCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .testTarget(name: "ArchivioCoreTests", dependencies: ["ArchivioCore"]),
    ],
    swiftLanguageModes: [.v5]
)
