// swift-tools-version:6.2
//
// Lokaler Fork von github.com/jakeheis/Shout (MIT).
//
// Unterschiede zum Original:
//  - libssh2 kommt NICHT mehr aus Homebrew/pkg-config (`.systemLibrary`),
//    sondern als vorgebautes statisches xcframework (siehe
//    scripts/build-libssh2-xcframework.sh). Dadurch baut der SSH-Stack auch
//    für iOS (Device + Simulator), nicht nur macOS.
//  - Das `CSSH`-Clang-Modul steckt jetzt in libssh2.xcframework/*/Headers
//    (shim.h + module.modulemap), statt in Sources/CSSH.
//  - OpenSSL (Krypto-Backend von libssh2) wird als openssl.xcframework nur
//    gelinkt — niemand importiert es.
//
import PackageDescription

let package = Package(
    name: "Shout",
    platforms: [
        .macOS(.v14),
        .iOS(.v26),
    ],
    products: [
        .library(name: "Shout", targets: ["Shout"]),
    ],
    dependencies: [
        .package(url: "https://github.com/IBM-Swift/BlueSocket", from: "1.0.46"),
    ],
    targets: [
        .binaryTarget(name: "CSSH", path: "../libssh2.xcframework"),
        .binaryTarget(name: "COpenSSL", path: "../openssl.xcframework"),
        .target(
            name: "Shout",
            dependencies: [
                "CSSH",
                "COpenSSL",
                .product(name: "Socket", package: "BlueSocket"),
            ],
            // Shout ist Pre-Concurrency-Code; Swift-6-Strict-Concurrency würde
            // ihn ablehnen. Manifest bleibt 6.2 (für .iOS(.v26)), aber dieses
            // Target kompiliert im Swift-5-Sprachmodus.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
