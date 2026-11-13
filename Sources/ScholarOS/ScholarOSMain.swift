import AppKit
import Foundation
import SwiftUI
import ScholarCLIAndMCP
import ScholarModels
import ScholarStudioViews
import ScholarWorkbenchShell

// MARK: - Dual-Mode Headless CLI / Retina Exporter + Native macOS SwiftUI Workstation Entry (`ScholarOSMain`)

@main
public struct ScholarOSMain {
    @MainActor
    public static func main() {
        let rawUserArgs = Array(CommandLine.arguments.dropFirst()).filter { arg in
            !arg.hasPrefix("-psn_") && arg != "-NSDocumentRevisionsDebugMode" && arg != "YES" && arg != "NO"
        }

        let explicitCLILanguage = ScholarLocalizer.parseCLIArgument(rawUserArgs)
            ?? ProcessInfo.processInfo.environment["SCHOLAROS_LANG"].flatMap(ScholarLanguage.parse)
        if let explicitCLILanguage {
            ScholarLocalizer.shared.setLanguage(explicitCLILanguage)
        }
        let userArgs = ScholarLocalizer.strippingLanguageArguments(rawUserArgs)

        // Mode 1: Headless 2x Retina Screenshot & HTML Dossier Export (`--export-screenshots <dir> [--lang zh|en]`)
        if let exportIdx = userArgs.firstIndex(of: "--export-screenshots") {
            let outputDir: String
            if exportIdx + 1 < userArgs.count, !userArgs[exportIdx + 1].hasPrefix("--") {
                outputDir = userArgs[exportIdx + 1]
            } else {
                outputDir = "docs"
            }

            do {
                // Ensure AppKit font & graphics tables are initialized for headless ImageRenderer rasterization
                _ = NSApplication.shared
                NSApp?.appearance = NSAppearance(named: .aqua)
                let written = try ScholarScreenshotExportService.exportAllAssets(
                    to: URL(fileURLWithPath: outputDir),
                    language: explicitCLILanguage ?? ScholarLocalizer.shared.language
                )
                for url in written {
                    print("Exported \(url.path)")
                }
                Foundation.exit(0)
            } catch {
                fputs("ERROR [EXPORT_SCREENSHOTS]: \(error.localizedDescription)\n", stderr)
                Foundation.exit(2)
            }
        }

        // Mode 2: Headless 15-Subcommand CLI & Hardware-Gated MCP Server
        if !userArgs.isEmpty {
            final class CLIResultBox: @unchecked Sendable {
                var result: Result<String, Error>?
            }
            let box = CLIResultBox()
            let semaphore = DispatchSemaphore(value: 0)

            Task.detached {
                do {
                    let output = try await ScholarCLIRunner().execute(arguments: userArgs)
                    box.result = .success(output)
                } catch {
                    box.result = .failure(error)
                }
                semaphore.signal()
            }
            semaphore.wait()

            switch box.result {
            case .success(let output):
                if !output.isEmpty {
                    print(output)
                }
                Foundation.exit(0)
            case .failure(let error as ScholarOSError):
                fputs("[\(error.errorCodeIdentifier)] \(error.localizedDescription)\n", stderr)
                Foundation.exit(2)
            case .failure(let error):
                fputs("[ERR_RUNTIME] \(error.localizedDescription)\n", stderr)
                Foundation.exit(2)
            case .none:
                Foundation.exit(2)
            }
        }

        // Mode 3: Interactive Native macOS SwiftUI Academic Workstation
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        ScholarOSWorkbenchApp.main()
    }
}

/// Native macOS SwiftUI Application scene hosting `ScholarRootWorkbenchView` in Cambridge Linen & Library Forest Green.
public struct ScholarOSWorkbenchApp: App {
    @StateObject private var studioViewModel = ScholarStudioViewModel()
    @ObservedObject private var localizer = ScholarLocalizer.shared

    public init() {}

    public var body: some Scene {
        WindowGroup(
            localizer.L(
                "ScholarOS — Academic Research & LaTeX/Typst Workstation",
                "ScholarOS — 学术研究与 LaTeX/Typst 原生工作台"
            )
        ) {
            ScholarRootWorkbenchView(viewModel: studioViewModel)
                .frame(minWidth: 1180, idealWidth: 1360, minHeight: 760, idealHeight: 840)
                .background(CambridgeLinenPalette.cambridgeLinen)
                .preferredColorScheme(.light)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button(
                    localizer.L(
                        "Undo \(studioViewModel.undoRedo.topUndoActionTitle ?? "")",
                        "撤销 \(studioViewModel.undoRedo.topUndoActionTitle ?? "")"
                    )
                ) {
                    studioViewModel.performUndo()
                }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!studioViewModel.undoRedo.canUndo)

                Button(
                    localizer.L(
                        "Redo \(studioViewModel.undoRedo.topRedoActionTitle ?? "")",
                        "重做 \(studioViewModel.undoRedo.topRedoActionTitle ?? "")"
                    )
                ) {
                    studioViewModel.performRedo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!studioViewModel.undoRedo.canRedo)
            }

            CommandMenu(localizer.L("Studios", "学术工作台")) {
                ForEach(Array(ScholarStudioTab.allCases.enumerated()), id: \.element.id) { idx, tab in
                    Button(tab.localizedTitle(localizer.language)) {
                        studioViewModel.docking.activeStudioTab = tab
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: [.command])
                }

                Divider()

                Button(localizer.L("Command, Section & Citation Palette…", "全局命令、章节与引文面板…")) {
                    studioViewModel.docking.isCommandPalettePresented = true
                }
                .keyboardShortcut("k", modifiers: [.command])

                Button(localizer.L("Run JavaScriptCore Editorial Plugins", "运行 JavaScriptCore 顶会审稿插件")) {
                    studioViewModel.runEditorialPluginSuite()
                    studioViewModel.docking.activeStudioTab = .editorialAudit
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Divider()

                Button("切换语言 / Toggle Language (\(localizer.language == .zhHans ? "中文 → EN" : "EN → 中文"))") {
                    studioViewModel.handleCommandPaletteAction(.toggleLanguage)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }

        Settings {
            ScholarPreferencesSheetView(
                preferences: studioViewModel.preferences,
                isPresented: .constant(true),
                onSyncPluginsToDatabase: { plugins in
                    studioViewModel.syncPluginsToDatabase(plugins)
                }
            )
        }
    }
}
