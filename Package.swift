// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HFSelcall",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "HFSelcall", targets: ["HFSelcall"]),
        .executable(name: "selcall-cli", targets: ["selcall-cli"]),
        .library(name: "SelcallCore", targets: ["SelcallCore"]),
    ],
    targets: [
        .target(name: "SelcallCore", path: "Sources/SelcallCore"),
        .executableTarget(name: "HFSelcall", dependencies: ["SelcallCore"], path: "Sources/HFSelcall"),
        .executableTarget(name: "selcall-cli", dependencies: ["SelcallCore"], path: "Sources/selcall-cli"),
    ]
)
