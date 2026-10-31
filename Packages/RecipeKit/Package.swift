// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RecipeKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "RecipeKit", targets: ["RecipeKit"]),
    ],
    targets: [
        .target(
            name: "RecipeKit",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "RecipeKitTests",
            dependencies: ["RecipeKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
