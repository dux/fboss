// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "fBoss",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "fBoss",
            targets: ["FileExplorer"]
        )
    ],
    targets: [
        .systemLibrary(
            name: "CiMobileDevice",
            path: "CiMobileDevice",
            pkgConfig: "libimobiledevice-1.0",
            providers: [
                .brew(["libimobiledevice"])
            ]
        ),
        .systemLibrary(
            name: "CLibssh2",
            path: "CLibssh2",
            pkgConfig: "libssh2",
            providers: [
                .brew(["libssh2"])
            ]
        ),
        .executableTarget(
            name: "FileExplorer",
            dependencies: ["CiMobileDevice", "CLibssh2"],
            path: "app",
            exclude: ["Info.plist"],
            resources: [
                .copy("Resources/Icons"),
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/AppIcon.svg"),
                .copy("Resources/build-commit.txt"),
                .copy("Resources/marked.min.js"),
                .copy("Resources/highlight.min.js")
            ],
            linkerSettings: [
                .linkedFramework("NetFS")
            ]
        ),
        .testTarget(
            name: "FileExplorerTests",
            dependencies: ["FileExplorer"],
            path: "Tests"
        )
    ]
)
