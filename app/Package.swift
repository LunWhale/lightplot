// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LightPlotCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "LightPlotCore", targets: ["LightPlotCore"]),
        .library(name: "LightPlotUI", targets: ["LightPlotUI"]),
    ],
    dependencies: [
        // YAML 双向读写。选它的理由：
        //  · 应用要能读旧管线产出的 rig.yaml / cues.yaml（否则"兜底"是空话）
        //  · 也要能写出同样格式，让 Python 管线仍然能渲染同一份文件
        //  · MIT，纯 Swift，无 C 依赖，iOS 可用
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(
            name: "LightPlotCore",
            dependencies: ["Yams"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "LightPlotUI",
            dependencies: ["LightPlotCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "lpx",
            dependencies: ["LightPlotCore", "LightPlotUI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "LightPlotApp",
            dependencies: ["LightPlotCore", "LightPlotUI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LightPlotCoreTests",
            dependencies: ["LightPlotCore", "LightPlotUI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
