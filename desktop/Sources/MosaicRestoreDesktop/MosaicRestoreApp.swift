import DesktopSupport
import SwiftUI

@main
struct MosaicRestoreApp: App {
    var body: some Scene {
        WindowGroup {
            RestoreView()
                .frame(minWidth: 680, minHeight: 620)
        }
        .windowResizability(.contentSize)
    }
}

private struct RestoreView: View {
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
        .animation(.easeOut(duration: 0.2), value: model.errorMessage)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "wand.and.stars.inverse")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .shadow(color: Color.accentColor.opacity(0.24), radius: 14, y: 7)

            VStack(alignment: .leading, spacing: 3) {
                Text("MosaicRestore")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Restore video clarity on your Mac or your own cloud GPU.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label(model.provider == .local ? "Local" : "Cloud", systemImage: model.provider == .local ? "laptopcomputer" : "cloud")
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

                Picker("Processing location", selection: $model.provider) {
                    ForEach(RestoreProvider.allCases) { provider in
                        Label(provider.rawValue, systemImage: provider == .local ? "laptopcomputer" : "cloud")
                            .tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.isRunning)

                Text(model.provider == .local
                     ? "Runs privately on this Mac with Apple Silicon acceleration."
                     : "Uses your own NVIDIA account or host. GPU charges go directly to your provider.")
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

                    if model.provider == .local {
                        GlassTextField(title: "Local runtime", text: $model.providerRoot)
                    } else {
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
            Color(nsColor: .windowBackgroundColor)

            if !reduceTransparency {
                RadialGradient(
                    colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.12), .clear],
                    center: .topLeading,
                    startRadius: 20,
                    endRadius: 520
                )
                RadialGradient(
                    colors: [Color.cyan.opacity(colorScheme == .dark ? 0.08 : 0.06), .clear],
                    center: .bottomTrailing,
                    startRadius: 30,
                    endRadius: 460
                )
            }
        }
        .ignoresSafeArea()
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
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(reduceTransparency
                          ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                          : AnyShapeStyle(.ultraThinMaterial))
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
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.08), radius: 20, y: 9)
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
