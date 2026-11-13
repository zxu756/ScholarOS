// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScholarOS",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ScholarModels", targets: ["ScholarModels"]),
        .library(name: "ScholarMarkupAST", targets: ["ScholarMarkupAST"]),
        .library(name: "ScholarLSPEngine", targets: ["ScholarLSPEngine"]),
        .library(name: "ScholarBibAndCSL", targets: ["ScholarBibAndCSL"]),
        .library(name: "ScholarPDFProvenance", targets: ["ScholarPDFProvenance"]),
        .library(name: "ScholarCitationGraph", targets: ["ScholarCitationGraph"]),
        .library(name: "ScholarPRISMAEngine", targets: ["ScholarPRISMAEngine"]),
        .library(name: "ScholarProjectStore", targets: ["ScholarProjectStore"]),
        .library(name: "ScholarPluginSDK", targets: ["ScholarPluginSDK"]),
        .library(name: "ScholarCLIAndMCP", targets: ["ScholarCLIAndMCP"]),
        .library(name: "ScholarWorkbenchShell", targets: ["ScholarWorkbenchShell"]),
        .library(name: "ScholarStudioViews", targets: ["ScholarStudioViews"]),
        .executable(name: "ScholarOS", targets: ["ScholarOS"])
    ],
    targets: [
        .target(
            name: "ScholarModels",
            dependencies: []
        ),
        .target(
            name: "ScholarMarkupAST",
            dependencies: ["ScholarModels"]
        ),
        .target(
            name: "ScholarBibAndCSL",
            dependencies: ["ScholarModels"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "ScholarLSPEngine",
            dependencies: [
                "ScholarModels",
                "ScholarMarkupAST",
                "ScholarBibAndCSL"
            ]
        ),
        .target(
            name: "ScholarPDFProvenance",
            dependencies: ["ScholarModels"],
            linkerSettings: [
                .linkedFramework("PDFKit"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "ScholarCitationGraph",
            dependencies: ["ScholarModels"]
        ),
        .target(
            name: "ScholarPRISMAEngine",
            dependencies: ["ScholarModels"]
        ),
        .target(
            name: "ScholarProjectStore",
            dependencies: ["ScholarModels"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "ScholarPluginSDK",
            dependencies: [
                "ScholarModels",
                "ScholarMarkupAST",
                "ScholarBibAndCSL"
            ],
            linkerSettings: [
                .linkedFramework("JavaScriptCore")
            ]
        ),
        .target(
            name: "ScholarCLIAndMCP",
            dependencies: [
                "ScholarModels",
                "ScholarMarkupAST",
                "ScholarBibAndCSL",
                "ScholarLSPEngine",
                "ScholarPDFProvenance",
                "ScholarCitationGraph",
                "ScholarPRISMAEngine",
                "ScholarProjectStore",
                "ScholarPluginSDK"
            ]
        ),
        .target(
            name: "ScholarWorkbenchShell",
            dependencies: [
                "ScholarModels",
                "ScholarProjectStore",
                "ScholarPluginSDK"
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .target(
            name: "ScholarStudioViews",
            dependencies: [
                "ScholarModels",
                "ScholarMarkupAST",
                "ScholarBibAndCSL",
                "ScholarLSPEngine",
                "ScholarPDFProvenance",
                "ScholarCitationGraph",
                "ScholarPRISMAEngine",
                "ScholarProjectStore",
                "ScholarPluginSDK",
                "ScholarCLIAndMCP",
                "ScholarWorkbenchShell"
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("PDFKit")
            ]
        ),
        .executableTarget(
            name: "ScholarOS",
            dependencies: [
                "ScholarModels",
                "ScholarMarkupAST",
                "ScholarBibAndCSL",
                "ScholarLSPEngine",
                "ScholarPDFProvenance",
                "ScholarCitationGraph",
                "ScholarPRISMAEngine",
                "ScholarProjectStore",
                "ScholarPluginSDK",
                "ScholarCLIAndMCP",
                "ScholarWorkbenchShell",
                "ScholarStudioViews"
            ]
        ),
        .testTarget(
            name: "ScholarOSTests",
            dependencies: [
                "ScholarModels",
                "ScholarMarkupAST",
                "ScholarBibAndCSL",
                "ScholarLSPEngine",
                "ScholarPDFProvenance",
                "ScholarCitationGraph",
                "ScholarPRISMAEngine",
                "ScholarProjectStore",
                "ScholarPluginSDK",
                "ScholarCLIAndMCP",
                "ScholarWorkbenchShell"
            ]
        )
    ]
)
