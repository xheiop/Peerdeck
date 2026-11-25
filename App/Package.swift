// swift-tools-version: 6.0
import PackageDescription

// macOS app。用 SwiftPM 构建，再由 scripts/build-mac.sh 打成 .app（Info.plist 在 Resources/ 里）。
// iOS（M2）要用 Xcode 工程，到时候再加。
let package = Package(
    name: "PeerdeckApp",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../Packages/TorrentKit"),
    ],
    targets: [
        .executableTarget(
            name: "Peerdeck",
            dependencies: [
                .product(name: "TorrentKit", package: "TorrentKit"),
                .product(name: "QBittorrentClient", package: "TorrentKit"),
                .product(name: "TransmissionClient", package: "TorrentKit"),
                .product(name: "FloodClient", package: "TorrentKit"),
                .product(name: "SyncEngine", package: "TorrentKit"),
                .product(name: "MediaKit", package: "TorrentKit"),
            ],
            // Info.plist 和 *.xcstrings 都由 scripts/build-mac.sh 放进 .app（xcstrings 用 xcstringstool 编译），不走 SwiftPM 资源
            exclude: ["Resources"]
        ),
        // 模型层的单元测试：swift test --package-path App
        .testTarget(
            name: "PeerdeckTests",
            dependencies: ["Peerdeck"]
        ),
    ]
)
