import AVFoundation
import Combine
import SwiftUI
import UIKit

/// "Scan invitation": the camera with a viewfinder, in a sheet over the pairing screen. It closes
/// by itself when it has read an invitation for this app, handing its text to `onInvitation`.
struct OnboardingScannerSheet: View {
    private let onInvitation: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: OnboardingScannerModel
    @State private var instructionHeight: CGFloat = 0
    @State private var controlsHeight: CGFloat = 0

    /// - Parameter onInvitation: called once with the scanned invitation; the caller dismisses the sheet.
    init(onInvitation: @escaping (String) -> Void) {
        self.onInvitation = onInvitation
        _model = State(initialValue: Self.makeModel())
    }

    #if DEBUG
    /// A scanner without a camera that shows `state` (see `OnboardingDebugOptions`), for previews.
    init(simulating state: String) {
        onInvitation = { _ in }
        _model = State(initialValue: OnboardingScannerModel(simulating: state))
    }
    #endif

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Black around the picture; the page's own colour around a notice.
                .background((showsViewfinder ? Color.black : Theme.page).ignoresSafeArea())
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("screen-pair-scanner")
                .navigationTitle(OnboardingCopy.scan)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(OnboardingCopy.close) { dismiss() }
                            .accessibilityIdentifier("scanner-close-button")
                    }
                }
        }
        .presentationDetents([.large])
        .task {
            model.onInvitation = onInvitation
            await model.start()
        }
        // The camera is on only while this sheet is on screen and the app is in front.
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await model.start() }
            case .background: model.stop()
            default: break
            }
        }
        // Posted on whichever thread the capture system is on.
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.wasInterruptedNotification).receive(on: DispatchQueue.main)) { _ in
            model.interrupted()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.interruptionEndedNotification).receive(on: DispatchQueue.main)) { _ in
            model.interruptionEnded()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.runtimeErrorNotification).receive(on: DispatchQueue.main)) { _ in
            model.runtimeFailure()
        }
    }

    private var showsViewfinder: Bool {
        switch model.status {
        case .preparing, .scanning, .interrupted, .accepted: true
        case .denied, .restricted, .unavailable, .failed: false
        }
    }

    private static func makeModel() -> OnboardingScannerModel {
        #if DEBUG
        if let state = OnboardingDebugOptions.current.scanner { return OnboardingScannerModel(simulating: state) }
        #endif
        return OnboardingScannerModel()
    }

    @ViewBuilder
    private var content: some View {
        switch model.status {
        case .preparing, .scanning, .interrupted, .accepted:
            viewfinder
        case .denied:
            notice(OnboardingCopy.cameraDeniedTitle, OnboardingCopy.cameraDeniedMessage, systemImage: "camera.fill") {
                Button(OnboardingCopy.openSettings) {
                    if let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) }
                }
                .buttonStyle(.dm(.primary))
                .accessibilityIdentifier("scanner-settings-button")
                pasteInstead
            }
        case .restricted:
            notice(OnboardingCopy.cameraRestrictedTitle, OnboardingCopy.cameraRestrictedMessage, systemImage: "lock.fill") { pasteInstead }
        case .unavailable:
            notice(OnboardingCopy.cameraMissingTitle, OnboardingCopy.noCamera, systemImage: "camera.fill") { pasteInstead }
        case .failed:
            notice(OnboardingCopy.cameraFailedTitle, OnboardingCopy.cameraFailedMessage, systemImage: "exclamationmark.triangle.fill") {
                Button(OnboardingCopy.tryAgain) { Task { await model.start() } }
                    .buttonStyle(.dm(.primary))
                    .accessibilityIdentifier("scanner-retry-button")
                pasteInstead
            }
        }
    }

    private var pasteInstead: some View {
        Button(OnboardingCopy.pasteInstead) { dismiss() }
            .buttonStyle(.dm())
            .accessibilityIdentifier("scanner-paste-button")
    }

    /// A state without a picture: why, and what to do instead.
    private func notice(_ title: String, _ message: String, systemImage: String, @ViewBuilder actions: () -> some View) -> some View {
        PhaseContainer {
            EmptyStateView(title: title, message: message, systemImage: systemImage, actions: actions)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("scanner-notice")
        }
    }

    // MARK: - Viewfinder

    private var viewfinder: some View {
        GeometryReader { proxy in
            let side = windowSide(in: proxy.size)
            ZStack {
                if let session = model.camera?.session {
                    OnboardingScannerPreview(session: session, isRunning: model.status == .scanning)
                        .ignoresSafeArea(edges: .bottom)
                        .accessibilityHidden(true)
                } else {
                    #if DEBUG
                    // A simulated scanner has no picture; something lighter than the shade shows where it would be.
                    LinearGradient(colors: [Color(hex: 0x56564F), Color(hex: 0x2E2E2B)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .ignoresSafeArea(edges: .bottom)
                        .accessibilityHidden(true)
                    #endif
                }
                OnboardingScannerShade(side: side)
                windowContent
                    .frame(width: side - 24, height: side - 24)
                VStack(spacing: Theme.Spacing.m) {
                    Text(OnboardingCopy.scannerInstruction)
                        .dmFont(.bodyStrong)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .shadow(color: .black.opacity(0.6), radius: 3)
                        .accessibilityIdentifier("scanner-instruction")
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { instructionHeight = $0 })
                    Spacer(minLength: 0)
                    controls
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { controlsHeight = $0 })
                }
                .padding(Theme.Spacing.l)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: side)
        }
    }

    /// The bottom of the picture: what is wrong with the code in view, and the torch. Side by
    /// side where there is no height to stack them (a phone on its side).
    @ViewBuilder
    private var controls: some View {
        let layout = verticalSizeClass == .compact
            ? AnyLayout(HStackLayout(alignment: .bottom, spacing: Theme.Spacing.m))
            : AnyLayout(VStackLayout(spacing: Theme.Spacing.m))
        layout {
            if let rejection = model.rejection {
                BannerView(rejection, kind: .warning)
                    .background(Theme.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.banner, style: .continuous))
                    .frame(maxWidth: 460)
                    .accessibilityIdentifier("scanner-message")
                    .transition(.opacity)
            }
            if model.isTorchAvailable, model.status == .scanning {
                Button {
                    model.toggleTorch()
                } label: {
                    Image(systemName: model.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(model.isTorchOn ? Theme.onAccent : Theme.textPrimary)
                        .frame(width: 56, height: 56)
                        .background(model.isTorchOn ? Theme.accent : Theme.surface2.opacity(0.92), in: Circle())
                        .overlay { Circle().strokeBorder(Theme.border, lineWidth: Theme.Layout.hairline) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(OnboardingCopy.torch)
                .accessibilityValue(model.isTorchOn ? "On" : "Off")
                .accessibilityAddTraits(.isToggle)
                .accessibilityIdentifier("scanner-torch-button")
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.rejection)
    }

    /// What is drawn inside the window while there is no picture to look at there.
    @ViewBuilder
    private var windowContent: some View {
        switch model.status {
        case .preparing:
            VStack(spacing: Theme.Spacing.m) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.textSecondary)
                Text(OnboardingCopy.scannerPreparing)
                    .dmFont(.callout)
                    .foregroundStyle(Theme.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("scanner-status")
        case .interrupted:
            Text(OnboardingCopy.cameraInterrupted)
                .dmFont(.callout)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("scanner-status")
        case .accepted:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(Theme.good)
                .accessibilityLabel("Invitation scanned")
                .accessibilityIdentifier("scanner-status")
        default:
            EmptyView()
        }
    }

    /// The side of the square window: as large as leaves room for the instruction above it and
    /// the controls below, on any screen, either way up and at any text size. The window is
    /// centred, so the taller of the two decides.
    private func windowSide(in size: CGSize) -> CGFloat {
        let margin = max(instructionHeight, controlsHeight) + 2 * Theme.Spacing.l
        return max(120, min(320, size.width - 64, size.height - 2 * margin))
    }
}

/// Everything around the window, darkened, and the window's corner marks.
private struct OnboardingScannerShade: View {
    let side: CGFloat

    private static let radius: CGFloat = 26

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea(edges: .bottom)
                .mask {
                    Rectangle()
                        .ignoresSafeArea(edges: .bottom)
                        .overlay {
                            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                                .frame(width: side, height: side)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                }
            OnboardingScannerCorners(radius: Self.radius, arm: side * 0.16)
                .stroke(Theme.textPrimary, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                .frame(width: side, height: side)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The four corners of a rounded square, each with a short arm along both of its sides.
private nonisolated struct OnboardingScannerCorners: Shape {
    let radius: CGFloat
    let arm: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(radius, rect.width / 2, rect.height / 2)
        let a = min(arm, rect.width / 2 - r, rect.height / 2 - r)
        // Top left, then clockwise.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + r + a))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + r + a, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX - r - a, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + r + a))

        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - r - a))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX - r - a, y: rect.maxY))

        path.move(to: CGPoint(x: rect.minX + r + a, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r - a))
        return path
    }
}

#Preview("Scanner, no camera") {
    OnboardingScannerSheet { _ in }
        .demoEnvironment(.onboarding)
}

#if DEBUG
#Preview("Scanner") {
    OnboardingScannerSheet(simulating: "scanning")
        .demoEnvironment(.onboarding)
}

#Preview("Scanner, a desktop invitation in view") {
    OnboardingScannerSheet(simulating: "desktop")
        .demoEnvironment(.onboarding)
}

#Preview("Scanner, camera denied") {
    OnboardingScannerSheet(simulating: "denied")
        .demoEnvironment(.onboarding)
}
#endif
