// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Leaf",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Leaf", targets: ["LeafApp"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .systemLibrary(name: "CZlib", pkgConfig: "zlib"),
        .target(name: "LeafCore", dependencies: ["CSQLite", "CZlib"]),
        .executableTarget(name: "LeafApp", dependencies: ["LeafCore"], resources: [.copy("Resources/Web"), .copy("Resources/Guide.epub")]),
        .testTarget(name: "LeafCoreTests", dependencies: ["LeafCore"])
    ]
)
