// swift-tools-version: 6.0
//
// NaviMapKit — provider-neutral 4D navigation map platform.
//
// Layout and dependency rules are normative per docs/02-detailed-design.md §1
// and docs/03-implementation-details.md §1.2:
//   - NaviMapCore depends on nothing but Foundation.
//   - Scene/Offline depend only on Core; Runtime on Core+Scene.
//   - _PrimaryVectorRuntime is the ONLY target allowed to import MapboxMaps
//     (CI `provider-isolation` enforces this).
//   - NaviAviationMapKit transitively carries _RuntimeAssembly so that a host
//     app renders with a single `import NaviAviationMapKit` (D3).

import PackageDescription

let package = Package(
    name: "NaviMapKit",
    platforms: [
        .iOS(.v18),
        // No macOS support commitment (03 §1.1) — this only satisfies SwiftPM
        // platform resolution for the Mapbox dependency so portable targets
        // (Core/Scene/Offline/Testing) can `swift build` on a mac host.
        .macOS(.v14),
    ],
    products: [
        .library(name: "NaviMapKit", targets: ["NaviMapKit"]),
        .library(name: "NaviMapCore", targets: ["NaviMapCore"]),
        .library(name: "NaviMapScene", targets: ["NaviMapScene"]),
        .library(name: "NaviMapRuntime", targets: ["NaviMapRuntime"]),
        .library(name: "NaviMapOffline", targets: ["NaviMapOffline"]),
        .library(name: "NaviAviationMapKit", targets: ["NaviAviationMapKit"]),
        .library(name: "NaviMapTesting", targets: ["NaviMapTesting"]),
        // NaviMapNavigation / NaviMaritimeMapKit / NaviUASMapKit are internal
        // draft targets without products until their phases (02 §2, P8).
    ],
    dependencies: [
        // Pinned exactly: runtime behavior is validated against this version.
        .package(url: "https://github.com/mapbox/mapbox-maps-ios.git", exact: "11.17.0"),
    ],
    targets: [
        // MARK: Public layers

        .target(
            name: "NaviMapCore",
            dependencies: []
        ),
        .target(
            name: "NaviMapScene",
            dependencies: ["NaviMapCore"]
        ),
        .target(
            name: "NaviMapRuntime",
            dependencies: ["NaviMapCore", "NaviMapScene"]
        ),
        .target(
            name: "NaviMapOffline",
            dependencies: ["NaviMapCore"]
        ),
        .target(
            name: "NaviMapNavigation",
            dependencies: ["NaviMapCore"]
        ),
        .target(
            name: "NaviMapKit",
            dependencies: ["NaviMapCore", "NaviMapScene", "NaviMapRuntime", "NaviMapOffline"]
        ),

        // MARK: Domain profiles

        .target(
            name: "NaviAviationMapKit",
            dependencies: [
                "NaviMapKit",
                "NaviMapOffline",
                "_RuntimeAssembly",
            ]
        ),
        .target(
            name: "NaviMaritimeMapKit",
            dependencies: ["NaviMapKit"]
        ),
        .target(
            name: "NaviUASMapKit",
            dependencies: ["NaviMapKit"]
        ),

        // MARK: Testing support

        .target(
            name: "NaviMapTesting",
            dependencies: ["NaviMapCore", "NaviMapScene", "NaviMapRuntime", "NaviMapOffline"]
        ),

        // MARK: Internal runtimes

        .target(
            name: "_PrimaryVectorRuntime",
            dependencies: [
                "NaviMapRuntime",
                "_TileRuntimeBridge",
                .product(name: "MapboxMaps", package: "mapbox-maps-ios"),
            ]
        ),
        .target(
            name: "_TileRuntimeBridge",
            dependencies: ["NaviMapRuntime"]
        ),
        .target(
            name: "_RuntimeAssembly",
            dependencies: ["_PrimaryVectorRuntime", "_TileRuntimeBridge"]
        ),

        // MARK: Tests

        .testTarget(name: "NaviMapCoreTests", dependencies: ["NaviMapCore"]),
        .testTarget(name: "NaviMapSceneTests", dependencies: ["NaviMapScene", "NaviMapRuntime", "NaviMapTesting"]),
        .testTarget(name: "NaviMapRuntimeTests", dependencies: ["NaviMapRuntime", "NaviMapTesting"]),
        .testTarget(name: "NaviMapOfflineTests", dependencies: ["NaviMapOffline", "NaviMapTesting"]),
        .testTarget(name: "NaviMapKitTests", dependencies: ["NaviMapKit", "NaviMapTesting"]),
        .testTarget(name: "NaviAviationMapKitTests", dependencies: ["NaviAviationMapKit", "NaviMapTesting"]),
        .testTarget(
            name: "CompilePolicyTests",
            dependencies: ["NaviMapCore"],
            // Fixtures are compiled BY the policy harness script (some must
            // fail), never as members of this target.
            exclude: ["Fixtures"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
