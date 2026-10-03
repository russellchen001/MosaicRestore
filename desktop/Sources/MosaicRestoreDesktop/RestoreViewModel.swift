import AppKit
import DesktopSupport
import Foundation
import SwiftUI

@MainActor
final class RestoreViewModel: ObservableObject {
    @Published var inputURLs: [URL] = []
    @Published var outputURLs: [URL] = []
    @Published var provider: RestoreProvider = .local
    @Published var providerRoot = "~/MosaicRestore/benchmark/lada-upstream"
    @Published var jasnaRunner = ""
    @Published var progress = 0.0
    @Published var status = "Choose a video to begin"
    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var isAdvancedExpanded = false

    private var process: Process?
    private var cancelFile: URL?
    private var outputBuffer = ""

    var canRestore: Bool {
        !inputURLs.isEmpty && !isRunning && (provider == .local || !jasnaRunner.isEmpty)
    }

    func chooseInput() {
        let panel = NSOpenPanel()
        panel.title = "Choose a video"
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        inputURLs = panel.urls
        outputURLs = panel.urls.map {
            $0.deletingPathExtension().appendingPathExtension("restored.mp4")
        }
        status = inputURLs.count == 1 ? "Ready to restore" : "Ready to restore \(inputURLs.count) videos"
        progress = 0
    }

    func restore() {
        guard !inputURLs.isEmpty, inputURLs.count == outputURLs.count else { return }
        guard !outputURLs.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            errorMessage = "The output file already exists. Move or rename it, then try again."
            return
        }

        do {
            let coreURL = try locateCoreExecutable()
            let cancelURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("mosaic-restore-\(UUID().uuidString).cancel")
            let command = RestoreCommand(
                provider: provider,
                inputs: inputURLs,
                outputs: outputURLs,
                providerRoot: providerRoot,
                jasnaRunner: jasnaRunner,
                cancelFile: cancelURL
            )
            let task = Process()
            let outputPipe = Pipe()
            task.executableURL = coreURL
            task.arguments = command.arguments
            task.standardOutput = outputPipe
            task.standardError = outputPipe

            outputBuffer = ""
            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in self?.consume(text) }
            }
            task.terminationHandler = { [weak self] finished in
                Task { @MainActor in self?.finish(exitCode: finished.terminationStatus) }
            }

            try task.run()
            process = task
            cancelFile = cancelURL
            progress = 0
            status = "Preparing…"
            isRunning = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancel() {
        guard isRunning, let cancelFile else { return }
        do {
            try Data().write(to: cancelFile, options: .atomic)
            status = "Cancelling…"
        } catch {
            errorMessage = "Could not cancel the task: \(error.localizedDescription)"
        }
    }

    func showOutput() {
        guard !outputURLs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(outputURLs)
    }

    private func consume(_ text: String) {
        outputBuffer += text
        let lines = outputBuffer.split(separator: "\n", omittingEmptySubsequences: false)
        outputBuffer = lines.last.map(String.init) ?? ""
        for line in lines.dropLast().map(String.init) {
            if let percent = ProgressLineParser.percent(from: line) {
                progress = Double(percent) / 100
            }
            if let friendly = ProgressLineParser.friendlyStatus(from: line) {
                status = friendly
            }
            if line.contains("FAIL restore") {
                errorMessage = line.replacingOccurrences(of: "FAIL restore — ", with: "")
            }
        }
    }

    private func finish(exitCode: Int32) {
        isRunning = false
        process = nil
        if let cancelFile { try? FileManager.default.removeItem(at: cancelFile) }
        self.cancelFile = nil

        if exitCode == 0, !outputURLs.isEmpty,
           outputURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
            progress = 1
            status = "Complete"
        } else if status == "Cancelling…" || status == "Cancelled" {
            status = "Cancelled"
            progress = 0
        } else {
            status = "Restore failed"
            if errorMessage == nil { errorMessage = "Restoration stopped before producing an output." }
        }
    }

    private func locateCoreExecutable() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["MOSAIC_CORE_BIN"] {
            let url = URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        if let bundled = Bundle.main.url(forResource: "mosaic-core", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        throw NSError(
            domain: "MosaicRestoreDesktop",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Mosaic Core is missing. Rebuild the desktop app."]
        )
    }
}
