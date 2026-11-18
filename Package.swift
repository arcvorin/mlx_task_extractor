// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TaskBench",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MLXTaskExtractor", targets: ["MLXTaskExtractor"]),
        .executable(name: "TaskBench", targets: ["TaskBench"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm",
            .upToNextMinor(from: "3.32.3")
        ),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "MLXTaskExtractor",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ]
        ),
        .executableTarget(
            name: "TaskBench",
            dependencies: ["MLXTaskExtractor"]
        ),
        .testTarget(
            name: "MLXTaskExtractorTests",
            dependencies: ["MLXTaskExtractor"]
        ),
        .testTarget(
            name: "TaskBenchTests",
            dependencies: ["TaskBench", "MLXTaskExtractor"]
        )
    ]
)
