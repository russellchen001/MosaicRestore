// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MosaicRestoreDesktop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MosaicRestore", targets: ["MosaicRestoreDesktop"]),
        .executable(name: "MosaicRestoreContractCheck", targets: ["MosaicRestoreContractCheck"])
    ],
    targets: [
        .target(name: "DesktopSupport"),
        .executableTarget(
            name: "MosaicRestoreDesktop",
            dependencies: ["DesktopSupport"]
        ),
        .executableTarget(
            name: "MosaicRestoreContractCheck",
            dependencies: ["DesktopSupport"]
        )
    ]
)
