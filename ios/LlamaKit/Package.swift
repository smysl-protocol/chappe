// swift-tools-version: 5.9
// LlamaKit — тонкая обёртка-пакет вокруг официального llama.xcframework
// (релиз ggml-org/llama.cpp, пин b10107 — см. docs/llama_swift_plan.md §1).
//
// Сам xcframework в git НЕ хранится (большой бинарь): перед первой сборкой
// выполнить  scripts/fetch_llama_xcframework.sh  из корня репозитория.
import PackageDescription

let package = Package(
    name: "LlamaKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "llama", targets: ["llama"])
    ],
    targets: [
        .binaryTarget(name: "llama", path: "llama.xcframework")
    ]
)
