import DesktopSupport
import SwiftUI

@main
struct MosaicRestoreApp: App {
    var body: some Scene {
        WindowGroup {
            RestoreView()
                .frame(minWidth: 560, minHeight: 430)
        }
        .windowResizability(.contentSize)
    }
}

private struct RestoreView: View {
    @StateObject private var model = RestoreViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("MosaicRestore")
                .font(.largeTitle.bold())
            Text("Restore a video locally on your Mac.")
                .foregroundStyle(.secondary)

            Button {
                model.chooseInput()
            } label: {
                HStack {
                    Image(systemName: "film")
                    Text(model.inputURL?.lastPathComponent ?? "Choose Video")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .disabled(model.isRunning)

            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: model.progress)
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Advanced", isExpanded: $model.isAdvancedExpanded) {
                Form {
                    Picker("Processing", selection: $model.provider) {
                        ForEach(RestoreProvider.allCases) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    if model.provider == .local {
                        TextField("Local runtime", text: $model.providerRoot)
                    } else {
                        TextField("Cloud runner", text: $model.jasnaRunner)
                    }
                }
                .formStyle(.grouped)
                .padding(.top, 8)
            }

            HStack {
                if model.isRunning {
                    Button("Cancel", role: .destructive) { model.cancel() }
                } else {
                    Button("Restore") { model.restore() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canRestore)
                }
                Spacer()
                Button("Show Output") { model.showOutput() }
                    .disabled(model.status != "Complete")
            }
        }
        .padding(28)
        .alert("MosaicRestore", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
