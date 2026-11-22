// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TorrentKit",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "TorrentKit", targets: ["TorrentKit"]),
        .library(name: "QBittorrentClient", targets: ["QBittorrentClient"]),
        .library(name: "TransmissionClient", targets: ["TransmissionClient"]),
        .library(name: "FloodClient", targets: ["FloodClient"]),
        .library(name: "SyncEngine", targets: ["SyncEngine"]),
        .executable(name: "tcli", targets: ["tcli"]),
        .executable(name: "listbench", targets: ["listbench"]),
    ],
    targets: [
        .target(name: "TorrentKit"),
        .target(name: "QBittorrentClient", dependencies: ["TorrentKit"]),
        .target(name: "TransmissionClient", dependencies: ["TorrentKit"]),
        .target(name: "FloodClient", dependencies: ["TorrentKit"]),
        .target(name: "SyncEngine", dependencies: ["TorrentKit"]),
        .executableTarget(
            name: "tcli",
            dependencies: ["TorrentKit", "QBittorrentClient", "TransmissionClient", "FloodClient", "SyncEngine"]
        ),
        .executableTarget(name: "listbench", dependencies: ["TorrentKit", "SyncEngine"]),
        .testTarget(
            name: "TorrentKitTests",
            dependencies: ["TorrentKit", "QBittorrentClient", "TransmissionClient", "FloodClient", "SyncEngine"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
