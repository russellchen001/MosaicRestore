import AppKit
import DesktopSupport
import SwiftUI

@main
struct MosaicRestoreApp: App {
    var body: some Scene {
        WindowGroup {
            RestoreView()
                .frame(minWidth: 680, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

private struct RestoreView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model = RestoreViewModel()

    var body: some View {
        ZStack {
            WindowBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    inputCard
                    processingCard
                    progressCard

                    if let errorMessage = model.errorMessage {
                        GlassNotice(message: errorMessage) {
                            model.errorMessage = nil
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    advancedCard
                    actionBar
                }
                .padding(28)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.errorMessage)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 50, height: 50)
                .shadow(color: Color.black.opacity(0.18), radius: 12, y: 6)

            VStack(alignment: .leading, spacing: 3) {
                Text("MosaicRestore")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Restore video clarity on your Mac or your own cloud GPU.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label(model.provider.headerTitle, systemImage: model.provider.symbolName)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
        }
    }

    private var inputCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(title: "Input", systemImage: "film.stack")

                GlassActionButton(action: model.chooseInput, kind: .surface, isEnabled: !model.isRunning) {
                    HStack(spacing: 13) {
                        Image(systemName: model.inputURLs.isEmpty ? "plus" : "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(Color.accentColor.opacity(0.14), in: Circle())
                            .foregroundStyle(Color.accentColor)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(inputTitle)
                                .font(.body.weight(.semibold))
                                .lineLimit(1)
                            Text(model.inputURLs.isEmpty ? "Select one or more video files" : "Click to choose a different selection")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var processingCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(title: "Processing", systemImage: "slider.horizontal.3")

                GlassSegmentedControl(selection: $model.provider, isEnabled: !model.isRunning)

                Text(model.provider.descriptionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var progressCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    SectionLabel(title: "Progress", systemImage: statusSymbol)
                    Spacer()
                    Text("\(Int(model.progress * 100))%")
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                        .foregroundStyle(model.isRunning ? Color.accentColor : Color.secondary)
                        .monospacedDigit()
                }

                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)
                    .scaleEffect(x: 1, y: 1.35, anchor: .center)

                HStack(alignment: .firstTextBaseline) {
                    Text(model.status)
                        .font(.callout.weight(.medium))
                    Spacer()
                    if let estimate = model.cloudEstimate {
                        Text(estimate)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var advancedCard: some View {
        GlassCard {
            DisclosureGroup(isExpanded: $model.isAdvancedExpanded) {
                VStack(alignment: .leading, spacing: 14) {
                    Divider().opacity(0.5)

                    switch model.provider {
                    case .local:
                        GlassTextField(title: "Local runtime", text: $model.providerRoot)
                    case .agentCloud:
                        GlassTextField(title: "Agent cloud configuration", text: $model.agentCloudConfig)
                        Label("The external desktop agent owns GUI control, credentials, and session transport.", systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .nvidia:
                        GlassTextField(title: "Cloud configuration", text: $model.cloudConfig)
                        Label("Credentials and provider details stay outside MosaicRestore.", systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 14)
            } label: {
                SectionLabel(title: "Advanced", systemImage: "gearshape")
            }
            .disabled(model.isRunning)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            if model.isRunning {
                GlassActionButton(action: model.cancel, kind: .destructive) {
                    Label("Cancel", systemImage: "xmark")
                }
            } else {
                GlassActionButton(action: model.restore, kind: .prominent, isEnabled: model.canRestore) {
                    Label("Restore", systemImage: "wand.and.stars")
                }
            }

            Spacer()

            GlassActionButton(action: model.showOutput, kind: .secondary, isEnabled: model.status == "Complete") {
                Label("Show Output", systemImage: "folder")
            }
        }
    }

    private var inputTitle: String {
        if model.inputURLs.isEmpty { return "Choose Videos" }
        if model.inputURLs.count == 1 { return model.inputURLs[0].lastPathComponent }
        return "\(model.inputURLs.count) videos selected"
    }

    private var statusSymbol: String {
        if model.status == "Complete" { return "checkmark.circle.fill" }
        if model.isRunning { return "waveform.path.ecg" }
        return "circle.dotted"
    }
}

private struct WindowBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                WindowMaterial()

                RadialGradient(
                    colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.24 : 0.16), .clear],
                    center: .topLeading,
                    startRadius: 20,
                    endRadius: 520
                )
                RadialGradient(
                    colors: [Color.cyan.opacity(colorScheme == .dark ? 0.13 : 0.09), .clear],
                    center: .bottomTrailing,
                    startRadius: 30,
                    endRadius: 460
                )
                LinearGradient(
                    colors: [Color.white.opacity(colorScheme == .dark ? 0.025 : 0.12), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
            }
        }
        .ignoresSafeArea()
    }
}

private struct WindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        WindowMaterialHost()
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        (nsView as? WindowMaterialHost)?.configureWindowIfAvailable()
    }
}

private final class WindowMaterialHost: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .active
        isEmphasized = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindowIfAvailable()
    }

    fileprivate func configureWindowIfAvailable() {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
    }
}

private struct GlassCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(reduceTransparency
                              ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                              : AnyShapeStyle(.ultraThinMaterial))

                    if !reduceTransparency {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(colorScheme == .dark ? 0.09 : 0.3),
                                        Color.accentColor.opacity(colorScheme == .dark ? 0.035 : 0.025),
                                        Color.clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(colorScheme == .dark ? 0.22 : 0.72), Color.primary.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .overlay(alignment: .top) {
                if !reduceTransparency {
                    Capsule()
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.2 : 0.72))
                        .frame(height: 1)
                        .padding(.horizontal, 24)
                        .blur(radius: 0.25)
                }
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.09), radius: 22, y: 10)
    }
}

private struct GlassSegmentedControl: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var selectionNamespace

    @Binding var selection: RestoreProvider
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 5) {
            ForEach(RestoreProvider.allCases) { provider in
                Button {
                    selection = provider
                } label: {
                    Label(provider.segmentTitle, systemImage: provider.symbolName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(selection == provider ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    if selection == provider {
                        ZStack {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(reduceTransparency
                                      ? AnyShapeStyle(Color(nsColor: .selectedContentBackgroundColor).opacity(0.2))
                                      : AnyShapeStyle(.thinMaterial))
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.13 : 0.1))
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.72), lineWidth: 1)
                        }
                        .matchedGeometryEffect(id: "glass-selection", in: selectionNamespace)
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.08), radius: 8, y: 3)
                    }
                }
                .disabled(!isEnabled)
            }
        }
        .padding(5)
        .background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(reduceTransparency
                      ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                      : AnyShapeStyle(.ultraThinMaterial))
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(Color.primary.opacity(0.09), lineWidth: 1)
                }
        }
        .opacity(isEnabled ? 1 : 0.5)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82), value: selection)
        .accessibilityLabel("Processing location")
    }
}

private extension RestoreProvider {
    var segmentTitle: String {
        switch self {
        case .local: "This Mac"
        case .agentCloud: "Agent PC"
        case .nvidia: "Cloud GPU"
        }
    }

    var headerTitle: String {
        switch self {
        case .local: "Local"
        case .agentCloud: "Agent Cloud"
        case .nvidia: "Cloud"
        }
    }

    var symbolName: String {
        switch self {
        case .local: "laptopcomputer"
        case .agentCloud: "desktopcomputer"
        case .nvidia: "cloud"
        }
    }

    var descriptionText: String {
        switch self {
        case .local:
            "Runs privately on this Mac with Apple Silicon acceleration."
        case .agentCloud:
            "A remote desktop agent operates your rented GPU computer through its GUI session."
        case .nvidia:
            "Uses your own NVIDIA account or host. GPU charges go directly to your provider."
        }
    }
}

private struct SectionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(.primary)
    }
}

private struct GlassTextField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(title, text: $text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.1)))
        }
    }
}

private enum GlassActionKind {
    case prominent
    case secondary
    case surface
    case destructive
}

private struct GlassActionButton<Label: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @StateObject private var hoverState = HoverState()

    let action: () -> Void
    let kind: GlassActionKind
    let isEnabled: Bool
    let label: Label

    init(
        action: @escaping () -> Void,
        kind: GlassActionKind,
        isEnabled: Bool = true,
        @ViewBuilder label: () -> Label
    ) {
        self.action = action
        self.kind = kind
        self.isEnabled = isEnabled
        self.label = label()
    }

    var body: some View {
        Button(action: action) { buttonLabel }
        .buttonStyle(PressedGlassButtonStyle(reduceMotion: reduceMotion))
        .background {
            RoundedRectangle(cornerRadius: kind == .surface ? 13 : 12, style: .continuous)
                .fill(backgroundStyle)
                .overlay {
                    RoundedRectangle(cornerRadius: kind == .surface ? 13 : 12, style: .continuous)
                        .fill(Color.white.opacity(hoverState.isHovered && isEnabled ? (colorScheme == .dark ? 0.06 : 0.18) : 0))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: kind == .surface ? 13 : 12, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
        .shadow(color: shadowColor, radius: hoverState.isHovered ? 11 : 7, y: hoverState.isHovered ? 5 : 3)
        .opacity(isEnabled ? 1 : 0.46)
        .disabled(!isEnabled)
        .onHover { hoverState.isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hoverState.isHovered)
    }

    private var buttonLabel: some View {
        label
            .font(.body.weight(.semibold))
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, kind == .surface ? 14 : 18)
            .padding(.vertical, kind == .surface ? 12 : 10)
            .frame(maxWidth: kind == .surface ? .infinity : nil, alignment: .leading)
            .contentShape(Rectangle())
    }

    private var backgroundStyle: AnyShapeStyle {
        switch kind {
        case .prominent:
            return AnyShapeStyle(Color.accentColor.gradient)
        case .destructive:
            return AnyShapeStyle(Color.red.opacity(colorScheme == .dark ? 0.32 : 0.16))
        case .secondary, .surface:
            if reduceTransparency { return AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) }
            return AnyShapeStyle(.thinMaterial)
        }
    }

    private var foregroundStyle: AnyShapeStyle {
        switch kind {
        case .prominent: return AnyShapeStyle(Color.white)
        case .destructive: return AnyShapeStyle(Color.red)
        case .secondary, .surface: return AnyShapeStyle(Color.primary)
        }
    }

    private var borderColor: Color {
        switch kind {
        case .prominent: return .white.opacity(0.28)
        case .destructive: return .red.opacity(0.28)
        case .secondary, .surface: return .primary.opacity(0.1)
        }
    }

    private var shadowColor: Color {
        kind == .prominent ? Color.accentColor.opacity(0.22) : Color.black.opacity(colorScheme == .dark ? 0.2 : 0.06)
    }
}

@MainActor
private final class HoverState: ObservableObject {
    @Published var isHovered = false
}

private struct PressedGlassButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct GlassNotice: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(15)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.red.opacity(0.22)))
    }
}
