// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "MeetingScribe",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "MeetingScribe",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "SpeakerKit", package: "WhisperKit")
            ],
            // Info.plist は下のリンカ設定で実行ファイルに埋め込むので、リソースとしては扱わない。
            exclude: ["Info.plist"],
            linkerSettings: [
                // SPM 実行ファイルには .app バンドルの Info.plist が無く、そのままでは
                // マイクへのアクセス要求（TCC）がクラッシュする。実行ファイルの
                // __TEXT,__info_plist セクションに直接 Info.plist を埋め込むことで、
                // .app バンドル化なしでもマイク権限プロンプトを機能させる。
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/MeetingScribe/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "MeetingScribeTests",
            dependencies: ["MeetingScribe"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
