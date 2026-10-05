import AppKit
import DesktopSupport
import Foundation
import Security
import SwiftUI

enum UserProcessingMode: String, CaseIterable, Identifiable {
    case local
    case cloud

    var id: String { rawValue }
}

@MainActor
final class RestoreViewModel: ObservableObject {
    @Published var inputURLs: [URL] = []
    @Published var outputURLs: [URL] = []

    // Product-facing choice. Internal Core providers remain hidden.
    @Published var processingMode: UserProcessingMode = .local

    @Published var cloudEstimate: String?
    @Published var progress = 0.0
    @Published var status = "Choose a video to begin"
    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var isAdvancedExpanded = false

    @Published var outputDirectory: URL?
    @Published var cloudConnectionPath = ""
    @Published var revealOutputWhenComplete = true

    @Published var isCloudSetupPresented = false
    @Published var cloudServerAddress = ""
    @Published var cloudAccessToken = ""
    @Published var cloudSetupMessage: String?
    @Published var cloudSetupIsTesting = false
    @Published var cloudSetupTestPassed = false

    // Runtime implementation details stay outside the normal UI.
    private let providerRoot: String
    private let legacyCloudConfig =
        NSString(string: "~/.config/mosaicrestore/cloud.conf").expandingTildeInPath
    private let legacyAgentCloudConfig =
        NSString(string: "~/.config/mosaicrestore/agent-cloud.conf").expandingTildeInPath

    private var process: Process?
    private var cancelFile: URL?
    private var outputBuffer = ""

    private let defaults = UserDefaults.standard
    private let outputDirectoryKey = "MosaicRestore.outputDirectory"
    private let cloudConnectionKey = "MosaicRestore.cloudConnection"
    private let revealOutputKey = "MosaicRestore.revealOutput"

    private let cloudProfileName = "default"
    private let cloudKeychainService = "com.mosaicrestore.cloud"

    private var cloudSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/MosaicRestore/Cloud",
                isDirectory: true
            )
    }

    private var cloudProfilesDirectory: URL {
        cloudSupportDirectory
            .appendingPathComponent("profiles", isDirectory: true)
    }

    private var managedCloudConfigURL: URL {
        cloudSupportDirectory.appendingPathComponent("cloud.conf")
    }

    private var managedCloudProfileURL: URL {
        cloudProfilesDirectory
            .appendingPathComponent("\(cloudProfileName).conf")
    }

    private var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MosaicRestore", isDirectory: true)
    }

    private var logURL: URL {
        logDirectory.appendingPathComponent("MosaicRestore.log")
    }

    init() {
        if let override =
            ProcessInfo.processInfo.environment["MOSAIC_LADA_ROOT"],
           !override.isEmpty {

            providerRoot =
                NSString(string: override).expandingTildeInPath

        } else if let resources = Bundle.main.resourceURL {

            let bundledRuntime =
                resources
                    .appendingPathComponent("Runtime", isDirectory: true)
                    .appendingPathComponent("Lada", isDirectory: true)

            let bundledCLI =
                bundledRuntime.appendingPathComponent("lada-cli")

            if FileManager.default.isExecutableFile(
                atPath: bundledCLI.path
            ) {
                providerRoot = bundledRuntime.path
            } else {
                providerRoot =
                    NSString(
                        string:
                            "~/MosaicRestore/benchmark/lada-upstream"
                    ).expandingTildeInPath
            }

        } else {
            providerRoot =
                NSString(
                    string:
                        "~/MosaicRestore/benchmark/lada-upstream"
                ).expandingTildeInPath
        }

        if let savedOutput = defaults.string(forKey: outputDirectoryKey),
           !savedOutput.isEmpty {
            outputDirectory = URL(fileURLWithPath: savedOutput, isDirectory: true)
        }

        if defaults.object(forKey: revealOutputKey) != nil {
            revealOutputWhenComplete = defaults.bool(forKey: revealOutputKey)
        }

        if FileManager.default.fileExists(
            atPath: managedCloudConfigURL.path
        ) {
            cloudConnectionPath = managedCloudConfigURL.path
        } else if let savedCloud = defaults.string(forKey: cloudConnectionKey),
                  !savedCloud.isEmpty {
            cloudConnectionPath = savedCloud
        } else if FileManager.default.fileExists(atPath: legacyCloudConfig) {
            cloudConnectionPath = legacyCloudConfig
        } else if FileManager.default.fileExists(atPath: legacyAgentCloudConfig) {
            // Backward-compatible migration. UI still exposes only "Cloud".
            cloudConnectionPath = legacyAgentCloudConfig
        }

        rebuildOutputs()
    }

    var canRestore: Bool {
        guard !inputURLs.isEmpty,
              !isRunning,
              outputDirectory != nil else {
            return false
        }

        if processingMode == .cloud {
            return cloudConnectionIsConfigured
        }

        return true
    }

    var outputFolderDisplayName: String {
        outputDirectory?.path(percentEncoded: false) ?? "Choose an output folder"
    }

    var cloudConnectionIsConfigured: Bool {
        let path = expandedCloudConnectionPath
        return !path.isEmpty && FileManager.default.isReadableFile(atPath: path)
    }

    var cloudConnectionStatus: String {
        cloudConnectionIsConfigured ? "Configured" : "Not configured"
    }

    func chooseInput() {
        let panel = NSOpenPanel()
        panel.title = "Choose Videos"
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        inputURLs = panel.urls
        rebuildOutputs()

        status = inputURLs.count == 1
            ? "Ready to restore"
            : "Ready to restore \(inputURLs.count) videos"

        progress = 0
        cloudEstimate = nil
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Output Folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if let outputDirectory {
            panel.directoryURL = outputDirectory
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        outputDirectory = url
        defaults.set(url.path, forKey: outputDirectoryKey)
        rebuildOutputs()
        errorMessage = nil
    }

    func configureCloud() {
        cloudSetupMessage = nil
        cloudSetupTestPassed = false
        cloudAccessToken = ""

        if let saved = readManagedCloudEndpoint() {
            cloudServerAddress = saved
        } else {
            cloudServerAddress = ""
        }

        isCloudSetupPresented = true
    }

    func setCloudServerAddress(_ value: String) {
        cloudServerAddress = value
        cloudSetupTestPassed = false
        cloudSetupMessage = nil
    }

    func setCloudAccessToken(_ value: String) {
        cloudAccessToken = value
        cloudSetupTestPassed = false
        cloudSetupMessage = nil
    }

    func cancelCloudSetup() {
        isCloudSetupPresented = false
        cloudSetupIsTesting = false
        cloudSetupMessage = nil
        cloudSetupTestPassed = false
        cloudAccessToken = ""
    }

    func testCloudConnection() {
        guard !cloudSetupIsTesting else { return }

        let endpoint = cloudServerAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard validCloudEndpoint(endpoint) else {
            cloudSetupMessage =
                "Enter a valid HTTPS server address."
            cloudSetupTestPassed = false
            return
        }

        let token =
            cloudAccessToken.isEmpty
            ? readKeychainToken(account: cloudProfileName)
            : cloudAccessToken

        guard let token, !token.isEmpty else {
            cloudSetupMessage =
                "Enter your access token."
            cloudSetupTestPassed = false
            return
        }

        let adapter: URL

        do {
            adapter = try locateCloudAdapter()
        } catch {
            cloudSetupMessage = error.localizedDescription
            cloudSetupTestPassed = false
            return
        }

        cloudSetupIsTesting = true
        cloudSetupMessage = "Testing connection…"
        cloudSetupTestPassed = false

        let supportDirectory = cloudSupportDirectory
        let profilesDirectory = cloudProfilesDirectory
        let service = cloudKeychainService

        Task {
            do {
                let result = try await Task.detached(
                    priority: .userInitiated
                ) {
                    try Self.runCloudSetupTest(
                        endpoint: endpoint,
                        token: token,
                        adapter: adapter,
                        supportDirectory: supportDirectory,
                        profilesDirectory: profilesDirectory,
                        keychainService: service
                    )
                }.value

                cloudSetupIsTesting = false
                cloudSetupTestPassed = result
                cloudSetupMessage =
                    result
                    ? "Connection successful."
                    : "Connection failed."

            } catch {
                cloudSetupIsTesting = false
                cloudSetupTestPassed = false
                cloudSetupMessage = error.localizedDescription
            }
        }
    }

    func saveCloudSetup() {
        guard cloudSetupTestPassed else {
            cloudSetupMessage =
                "Test the connection successfully before saving."
            return
        }

        let endpoint = cloudServerAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard validCloudEndpoint(endpoint) else {
            cloudSetupMessage =
                "Enter a valid HTTPS server address."
            cloudSetupTestPassed = false
            return
        }

        do {
            let adapter = try locateCloudAdapter()

            try FileManager.default.createDirectory(
                at: cloudProfilesDirectory,
                withIntermediateDirectories: true
            )

            let token =
                cloudAccessToken.isEmpty
                ? readKeychainToken(account: cloudProfileName)
                : cloudAccessToken

            guard let token, !token.isEmpty else {
                throw NSError(
                    domain: "MosaicRestoreDesktop",
                    code: 20,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The cloud access token is missing."
                    ]
                )
            }

            try writeKeychainToken(
                token,
                account: cloudProfileName
            )

            let profile =
                """
                endpoint=\(endpoint)
                token_account=\(cloudProfileName)
                timeout_seconds=30
                """

            try profile.write(
                to: managedCloudProfileURL,
                atomically: true,
                encoding: .utf8
            )

            let config =
                """
                version=1
                adapter=\(adapter.path)
                profile=\(cloudProfileName)
                status_retries=5
                poll_millis=1000
                """

            try config.write(
                to: managedCloudConfigURL,
                atomically: true,
                encoding: .utf8
            )

            cloudConnectionPath = managedCloudConfigURL.path
            defaults.set(
                cloudConnectionPath,
                forKey: cloudConnectionKey
            )

            cloudAccessToken = ""
            cloudSetupMessage = nil
            cloudSetupTestPassed = false
            isCloudSetupPresented = false
            errorMessage = nil

        } catch {
            cloudSetupMessage = error.localizedDescription
        }
    }

    func clearCloudConnection() {
        cloudConnectionPath = ""
        defaults.removeObject(forKey: cloudConnectionKey)
        cloudEstimate = nil

        try? FileManager.default.removeItem(
            at: managedCloudConfigURL
        )

        try? FileManager.default.removeItem(
            at: managedCloudProfileURL
        )

        deleteKeychainToken(account: cloudProfileName)
    }

    func setRevealOutputWhenComplete(_ enabled: Bool) {
        revealOutputWhenComplete = enabled
        defaults.set(enabled, forKey: revealOutputKey)
    }

    func restore() {
        guard !inputURLs.isEmpty else { return }

        guard let outputDirectory else {
            errorMessage = "Choose an output folder before starting."
            return
        }

        guard validateOutputDirectory(outputDirectory) else {
            errorMessage = "The selected output folder is not writable. Choose another folder."
            return
        }

        rebuildOutputs()

        guard inputURLs.count == outputURLs.count else {
            errorMessage = "Could not prepare the output files."
            return
        }

        guard !outputURLs.contains(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            errorMessage =
                "An output file already exists in the selected folder. Move or rename it, then try again."
            return
        }

        let resolvedProvider: RestoreProvider
        let resolvedCloudConfig: String
        let resolvedAgentConfig: String

        switch processingMode {
        case .local:
            resolvedProvider = .local
            resolvedCloudConfig = ""
            resolvedAgentConfig = ""

        case .cloud:
            guard cloudConnectionIsConfigured else {
                errorMessage =
                    "Cloud is not configured. Open Advanced and configure Cloud."
                return
            }

            let route = detectCloudRoute(at: expandedCloudConnectionPath)

            switch route {
            case .agent:
                resolvedProvider = .agentCloud
                resolvedCloudConfig = ""
                resolvedAgentConfig = expandedCloudConnectionPath

            case .headless:
                resolvedProvider = .nvidia
                resolvedCloudConfig = expandedCloudConnectionPath
                resolvedAgentConfig = ""
            }
        }

        errorMessage = nil
        cloudEstimate = nil

        do {
            try prepareLogDirectory()

            let coreURL = try locateCoreExecutable()
            let cancelURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "mosaic-restore-\(UUID().uuidString).cancel"
                )

            let command = RestoreCommand(
                provider: resolvedProvider,
                inputs: inputURLs,
                outputs: outputURLs,
                providerRoot: providerRoot,
                cloudConfig: resolvedCloudConfig,
                agentCloudConfig: resolvedAgentConfig,
                cancelFile: cancelURL
            )

            appendLog(
                """
                ---- Restore started ----
                mode=\(processingMode.rawValue)
                inputs=\(inputURLs.count)
                outputDirectory=\(outputDirectory.path)
                """
            )

            let task = Process()
            let outputPipe = Pipe()

            task.executableURL = coreURL
            task.arguments = command.arguments
            task.standardOutput = outputPipe
            task.standardError = outputPipe

            var environment = ProcessInfo.processInfo.environment

            if let resources = Bundle.main.resourceURL {
                let mediaBin =
                    resources
                        .appendingPathComponent(
                            "Runtime/Lada/_internal/bin",
                            isDirectory: true
                        )

                let ffmpeg =
                    mediaBin.appendingPathComponent("ffmpeg")

                let ffprobe =
                    mediaBin.appendingPathComponent("ffprobe")

                if FileManager.default.isExecutableFile(
                    atPath: ffmpeg.path
                ),
                FileManager.default.isExecutableFile(
                    atPath: ffprobe.path
                ) {
                    environment["MOSAIC_MEDIA_BIN_DIR"] =
                        mediaBin.path
                }
            }

            task.environment = environment

            outputBuffer = ""

            outputPipe.fileHandleForReading.readabilityHandler = {
                [weak self] handle in

                let data = handle.availableData

                guard !data.isEmpty,
                      let text = String(data: data, encoding: .utf8) else {
                    return
                }

                Task { @MainActor in
                    self?.appendLog(text)
                    self?.consume(text)
                }
            }

            task.terminationHandler = { [weak self] finished in
                Task { @MainActor in
                    self?.finish(exitCode: finished.terminationStatus)
                }
            }

            try task.run()

            process = task
            cancelFile = cancelURL
            progress = 0
            status = "Preparing…"
            isRunning = true

        } catch {
            errorMessage = error.localizedDescription
            appendLog("ERROR \(error.localizedDescription)")
        }
    }

    func cancel() {
        guard isRunning, let cancelFile else { return }

        do {
            try Data().write(to: cancelFile, options: .atomic)
            status = "Cancelling…"
        } catch {
            errorMessage =
                "Could not cancel the task: \(error.localizedDescription)"
        }
    }

    func showOutput() {
        if !outputURLs.isEmpty,
           outputURLs.contains(where: {
               FileManager.default.fileExists(atPath: $0.path)
           }) {
            NSWorkspace.shared.activateFileViewerSelecting(outputURLs)
            return
        }

        if let outputDirectory {
            NSWorkspace.shared.open(outputDirectory)
        }
    }

    func openLogs() {
        do {
            try prepareLogDirectory()

            if !FileManager.default.fileExists(atPath: logURL.path) {
                try Data().write(to: logURL)
            }

            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        } catch {
            errorMessage = "Could not open logs: \(error.localizedDescription)"
        }
    }

    func exportDiagnosticReport() {
        let panel = NSSavePanel()
        panel.title = "Export Diagnostic Report"
        panel.nameFieldStringValue = "MosaicRestore-Diagnostics.txt"

        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }

        let logText =
            (try? String(contentsOf: logURL, encoding: .utf8))
            ?? "No log has been created yet."

        let report =
            """
            MosaicRestore Diagnostic Report
            ===============================

            App: \(Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown")

            Build: \(Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown")

            macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
            Processing mode: \(processingMode.rawValue)
            Cloud configuration: \(cloudConnectionStatus)
            Output folder configured: \(outputDirectory != nil)

            ---- Log ----
            \(logText)
            """

        do {
            try report.write(
                to: destination,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            errorMessage =
                "Could not export diagnostics: \(error.localizedDescription)"
        }
    }

    private func validCloudEndpoint(_ value: String) -> Bool {
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            return false
        }

        return true
    }

    private func locateCloudAdapter() throws -> URL {
        if let override =
            ProcessInfo.processInfo.environment[
                "MOSAIC_CLOUD_ADAPTER"
            ],
           !override.isEmpty {

            let url = URL(
                fileURLWithPath:
                    NSString(string: override)
                        .expandingTildeInPath
            )

            if FileManager.default.isExecutableFile(
                atPath: url.path
            ) {
                return url
            }
        }

        if let resources = Bundle.main.resourceURL {
            let bundled =
                resources
                    .appendingPathComponent(
                        "Cloud",
                        isDirectory: true
                    )
                    .appendingPathComponent(
                        "mosaic-cloud-adapter"
                    )

            if FileManager.default.isExecutableFile(
                atPath: bundled.path
            ) {
                return bundled
            }
        }

        throw NSError(
            domain: "MosaicRestoreDesktop",
            code: 21,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The Cloud component is missing. Rebuild MosaicRestore."
            ]
        )
    }

    private func readManagedCloudEndpoint() -> String? {
        guard let contents =
            try? String(
                contentsOf: managedCloudProfileURL,
                encoding: .utf8
            ) else {
            return nil
        }

        for rawLine in contents.split(
            whereSeparator: \.isNewline
        ) {
            let line = String(rawLine)

            guard let split = line.firstIndex(of: "=") else {
                continue
            }

            let key = String(line[..<split])
                .trimmingCharacters(in: .whitespaces)

            if key == "endpoint" {
                return String(
                    line[line.index(after: split)...]
                ).trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            }
        }

        return nil
    }

    private func readKeychainToken(
        account: String
    ) -> String? {
        let query: [String: Any] = [
            kSecClass as String:
                kSecClassGenericPassword,
            kSecAttrService as String:
                cloudKeychainService,
            kSecAttrAccount as String:
                account,
            kSecReturnData as String:
                true,
            kSecMatchLimit as String:
                kSecMatchLimitOne
        ]

        var item: CFTypeRef?

        let status =
            SecItemCopyMatching(
                query as CFDictionary,
                &item
            )

        guard status == errSecSuccess,
              let data = item as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private func writeKeychainToken(
        _ token: String,
        account: String
    ) throws {
        deleteKeychainToken(account: account)

        let query: [String: Any] = [
            kSecClass as String:
                kSecClassGenericPassword,
            kSecAttrService as String:
                cloudKeychainService,
            kSecAttrAccount as String:
                account,
            kSecValueData as String:
                Data(token.utf8)
        ]

        let status =
            SecItemAdd(
                query as CFDictionary,
                nil
            )

        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not save the cloud access token."
                ]
            )
        }
    }

    private func deleteKeychainToken(
        account: String
    ) {
        let query: [String: Any] = [
            kSecClass as String:
                kSecClassGenericPassword,
            kSecAttrService as String:
                cloudKeychainService,
            kSecAttrAccount as String:
                account
        ]

        SecItemDelete(query as CFDictionary)
    }

    nonisolated private static func runCloudSetupTest(
        endpoint: String,
        token: String,
        adapter: URL,
        supportDirectory: URL,
        profilesDirectory: URL,
        keychainService: String
    ) throws -> Bool {
        let testProfile = "setup-test-\(UUID().uuidString)"

        try FileManager.default.createDirectory(
            at: profilesDirectory,
            withIntermediateDirectories: true
        )

        let profileURL =
            profilesDirectory
                .appendingPathComponent(
                    "\(testProfile).conf"
                )

        let profile =
            """
            endpoint=\(endpoint)
            token_account=\(testProfile)
            timeout_seconds=15
            """

        try profile.write(
            to: profileURL,
            atomically: true,
            encoding: .utf8
        )

        let keychainQuery: [String: Any] = [
            kSecClass as String:
                kSecClassGenericPassword,
            kSecAttrService as String:
                keychainService,
            kSecAttrAccount as String:
                testProfile,
            kSecValueData as String:
                Data(token.utf8)
        ]

        SecItemDelete(
            [
                kSecClass as String:
                    kSecClassGenericPassword,
                kSecAttrService as String:
                    keychainService,
                kSecAttrAccount as String:
                    testProfile
            ] as CFDictionary
        )

        let addStatus =
            SecItemAdd(
                keychainQuery as CFDictionary,
                nil
            )

        guard addStatus == errSecSuccess else {
            try? FileManager.default.removeItem(
                at: profileURL
            )

            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(addStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not prepare the secure Cloud test."
                ]
            )
        }

        defer {
            try? FileManager.default.removeItem(
                at: profileURL
            )

            SecItemDelete(
                [
                    kSecClass as String:
                        kSecClassGenericPassword,
                    kSecAttrService as String:
                        keychainService,
                    kSecAttrAccount as String:
                        testProfile
                ] as CFDictionary
            )
        }

        let process = Process()
        let pipe = Pipe()

        process.executableURL = adapter
        process.arguments = [
            "validate",
            "--profile",
            testProfile
        ]

        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data =
            pipe.fileHandleForReading
                .readDataToEndOfFile()

        let text =
            String(
                data: data,
                encoding: .utf8
            ) ?? ""

        guard process.terminationStatus == 0 else {
            let clean =
                text
                    .split(whereSeparator: \.isNewline)
                    .map(String.init)
                    .first {
                        $0.hasPrefix("message=")
                    }?
                    .replacingOccurrences(
                        of: "message=",
                        with: ""
                    )

            throw NSError(
                domain: "MosaicRestoreDesktop",
                code: 22,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        clean ?? "Cloud connection failed."
                ]
            )
        }

        return text.contains("contract_version=1")
    }

    private enum CloudRoute {
        case headless
        case agent
    }

    private var expandedCloudConnectionPath: String {
        NSString(string: cloudConnectionPath).expandingTildeInPath
    }

    private func detectCloudRoute(at path: String) -> CloudRoute {
        guard let contents =
            try? String(contentsOfFile: path, encoding: .utf8) else {
            return .headless
        }

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
                .trimmingCharacters(in: .whitespaces)

            guard !line.hasPrefix("#"),
                  let split = line.firstIndex(of: "=") else {
                continue
            }

            let key = String(line[..<split])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()

            let value = String(line[line.index(after: split)...])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()

            if key == "transport" {
                if value == "agent-gui" || value == "agent" {
                    return .agent
                }

                return .headless
            }
        }

        // Backward compatibility with the already-accepted legacy profile.
        if URL(fileURLWithPath: path)
            .lastPathComponent
            .lowercased()
            .contains("agent") {
            return .agent
        }

        return .headless
    }

    private func validateOutputDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ),
        isDirectory.boolValue else {
            return false
        }

        return FileManager.default.isWritableFile(atPath: url.path)
    }

    private func rebuildOutputs() {
        guard let outputDirectory else {
            outputURLs = []
            return
        }

        outputURLs = inputURLs.map { input in
            let name = input.deletingPathExtension().lastPathComponent
            return outputDirectory
                .appendingPathComponent("\(name).restored.mp4")
        }
    }

    private func consume(_ text: String) {
        outputBuffer += text

        let lines =
            outputBuffer.split(
                separator: "\n",
                omittingEmptySubsequences: false
            )

        outputBuffer = lines.last.map(String.init) ?? ""

        for line in lines.dropLast().map(String.init) {
            if let percent = ProgressLineParser.percent(from: line) {
                progress = Double(percent) / 100
            }

            if let friendly = ProgressLineParser.friendlyStatus(from: line) {
                status = friendly
            }

            if let estimate = ProgressLineParser.cloudEstimate(from: line) {
                cloudEstimate = estimate
            }

            if line.contains("FAIL restore") {
                errorMessage =
                    line.replacingOccurrences(
                        of: "FAIL restore — ",
                        with: ""
                    )
            }
        }
    }

    private func finish(exitCode: Int32) {
        isRunning = false
        process = nil

        if let cancelFile {
            try? FileManager.default.removeItem(at: cancelFile)
        }

        self.cancelFile = nil

        if exitCode == 0,
           !outputURLs.isEmpty,
           outputURLs.allSatisfy({
               FileManager.default.fileExists(atPath: $0.path)
           }) {

            progress = 1
            status = "Complete"
            appendLog("Restore completed successfully.")

            if revealOutputWhenComplete {
                showOutput()
            }

        } else if status == "Cancelling…" || status == "Cancelled" {

            status = "Cancelled"
            progress = 0
            appendLog("Restore cancelled.")

        } else {

            status = "Restore failed"

            if errorMessage == nil {
                errorMessage =
                    "Restoration stopped before producing an output."
            }

            appendLog("Restore failed with exit code \(exitCode).")
        }
    }

    private func prepareLogDirectory() throws {
        try FileManager.default.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true
        )
    }

    private func appendLog(_ text: String) {
        try? prepareLogDirectory()

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] \(text)\n"

        guard let data = entry.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {

            defer { try? handle.close() }

            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // Logging must never interrupt restoration.
            }

        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    private func locateCoreExecutable() throws -> URL {
        if let override =
            ProcessInfo.processInfo.environment["MOSAIC_CORE_BIN"] {

            let url = URL(
                fileURLWithPath:
                    NSString(string: override).expandingTildeInPath
            )

            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        if let bundled =
            Bundle.main.url(
                forResource: "mosaic-core",
                withExtension: nil
            ),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        throw NSError(
            domain: "MosaicRestoreDesktop",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Mosaic Core is missing. Rebuild the desktop app."
            ]
        )
    }
}
