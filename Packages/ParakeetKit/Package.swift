// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ParakeetKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ParakeetKit", targets: ["ParakeetKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.6"),
    ],
    targets: [
        .target(
            name: "ParakeetKit",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
            ]
        ),
        .testTarget(
            name: "ParakeetKitTests",
            dependencies: ["ParakeetKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
