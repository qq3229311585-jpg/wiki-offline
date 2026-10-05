// swift-tools-version: 6.0
// 维基离线 —— macOS 原生离线英文维基百科阅读器
//
// 构建：./build.sh   （产物：../维基离线.app）
// 测试：./test.sh    （单元测试 + 合成测试 ZIM）
import PackageDescription

let brew = "/opt/homebrew/opt"
let zimInclude = "-I\(brew)/libzim/include"
let zimLib = "-L\(brew)/libzim/lib"

let package = Package(
    name: "WikiOffline",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "WikiOffline", targets: ["WikiOffline"]),
        .executable(name: "WikiOnline", targets: ["WikiOnline"]),
        .executable(name: "wikitool", targets: ["wikitool"]),
        .executable(name: "makezim", targets: ["makezim"]),
    ],
    targets: [
        // Objective-C++ 薄桥：把 libzim (C++) 暴露给 Swift
        .target(
            name: "CZim",
            path: "Sources/CZim",
            cxxSettings: [.unsafeFlags([zimInclude, "-fobjc-arc"])],
            linkerSettings: [
                .unsafeFlags([zimLib]),
                .linkedLibrary("zim"),
                .linkedLibrary("c++"),
            ]
        ),
        // 纯逻辑：ZIM 访问、HTML 清洗、缓存、存储、翻译调度 —— 可单元测试
        .target(
            name: "WikiCore",
            dependencies: ["CZim"],
            path: "Sources/WikiCore"
        ),
        // SwiftUI App
        .executableTarget(
            name: "WikiOffline",
            dependencies: ["WikiCore"],
            path: "Sources/WikiOffline",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        // 在线版 SwiftUI App（共享 WikiCore；数据来自维基百科网络接口）
        .executableTarget(
            name: "WikiOnline",
            dependencies: ["WikiCore"],
            path: "Sources/WikiOnline",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        // 命令行验证工具：打开 ZIM、搜索、取文章、清洗、计时
        .executableTarget(
            name: "wikitool",
            dependencies: ["WikiCore"],
            path: "Sources/wikitool"
        ),
        // 预翻译 worker（无界面、可断点续跑；由守护脚本拉起）
        .executableTarget(
            name: "wikipretranslate",
            dependencies: ["WikiCore"],
            path: "Sources/wikipretranslate",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("IOKit"),
            ]
        ),
        // 生成合成测试 ZIM（libzim writer），用于没有真实数据时联调
        .executableTarget(
            name: "makezim",
            path: "Sources/makezim",
            cxxSettings: [.unsafeFlags([zimInclude])],
            linkerSettings: [
                .unsafeFlags([zimLib]),
                .linkedLibrary("zim"),
            ]
        ),
        .testTarget(
            name: "WikiCoreTests",
            dependencies: ["WikiCore"],
            path: "Tests/WikiCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
