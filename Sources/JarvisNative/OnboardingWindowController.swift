import AppKit
import SwiftUI

// MARK: - Window Controller

@MainActor
final class OnboardingWindowController {
  private static let completedKey = "hasCompletedOnboarding"

  static var hasCompletedOnboarding: Bool {
    get { UserDefaults.standard.bool(forKey: completedKey) }
    set { UserDefaults.standard.set(newValue, forKey: completedKey) }
  }

  private var window: NSWindow?
  var onFinished: (() -> Void)?

  func show(model: AppModel) {
    if let existing = window, existing.isVisible {
      existing.makeKeyAndOrderFront(nil)
      return
    }

    let view = OnboardingView(model: model) { [weak self] in
      Self.hasCompletedOnboarding = true
      self?.window?.close()
      self?.window = nil
      self?.onFinished?()
    }

    let w = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    w.titlebarAppearsTransparent = true
    w.titleVisibility = .hidden
    w.isMovableByWindowBackground = true
    w.backgroundColor = NSColor(white: 0.07, alpha: 1)
    w.appearance = NSAppearance(named: .darkAqua)
    w.contentViewController = NSHostingController(rootView: view)
    w.center()
    w.isReleasedWhenClosed = false
    w.level = .floating

    w.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    self.window = w
  }

  var isVisible: Bool { window?.isVisible ?? false }
}

// MARK: - Main Onboarding View

private struct OnboardingView: View {
  @ObservedObject var model: AppModel
  let onComplete: () -> Void

  @State private var step = 0
  private let totalSteps = 7

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        cardForStep(step)
          .id(step)
          .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
          ))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipped()

      bottomBar
    }
    .frame(width: 480, height: 600)
    .background(Color(white: 0.07))
    .environment(\.colorScheme, .dark)
    .task {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        model.refreshPermissions(force: true)
      }
    }
  }

  // MARK: - Bottom Bar

  private var bottomBar: some View {
    VStack(spacing: 14) {
      if step > 0 {
        HStack(spacing: 6) {
          ForEach(0..<totalSteps, id: \.self) { i in
            Circle()
              .fill(i == step ? Color.white.opacity(0.8) : Color.white.opacity(0.15))
              .frame(width: 6, height: 6)
              .scaleEffect(i == step ? 1.15 : 1)
              .animation(.easeOut(duration: 0.2), value: step)
          }
        }
      }

      Button {
        advance()
      } label: {
        Text(continueLabel)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.black)
          .frame(maxWidth: 280)
          .padding(.vertical, 11)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(.white.opacity(isContinueDisabled ? 0.35 : 0.9))
          )
      }
      .buttonStyle(.plain)
      .disabled(isContinueDisabled)
    }
    .padding(.bottom, 28)
    .padding(.top, 8)
  }

  private var continueLabel: String {
    switch step {
    case 0: return "I Understand"
    case 1:
      if !model.settings.hasApiKey && !model.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "Save & Continue"
      }
      return model.settings.hasApiKey ? "Continue" : "Enter Key to Continue"
    case totalSteps - 1: return "Get Started"
    default: return "Continue"
    }
  }

  private var isContinueDisabled: Bool {
    step == 1 && !model.settings.hasApiKey && model.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func advance() {
    if step == 1 && !model.settings.hasApiKey {
      Task {
        await model.saveApiKey()
        if model.settings.hasApiKey {
          goNext()
        }
      }
      return
    }

    if step >= totalSteps - 1 {
      onComplete()
      return
    }

    goNext()
  }

  private func goNext() {
    withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
      step += 1
    }
  }

  // MARK: - Card Factory

  @ViewBuilder
  private func cardForStep(_ s: Int) -> some View {
    switch s {
    case 0: welcomeCard
    case 1: apiKeyCard
    case 2: hotkeyCard
    case 3: microphoneCard
    case 4: screenRecordingCard
    case 5: accessibilityCard
    case 6: filesAccessCard
    default: EmptyView()
    }
  }

  // MARK: - Step 0: Welcome

  private var welcomeCard: some View {
    CardLayout(accentColor: .white) {
      WelcomeLogoAnimation()
    } content: {
      VStack(spacing: 14) {
        Text("Welcome to Jarvis")
          .font(.system(size: 24, weight: .bold))

        Text("Jarvis is a voice meta-controller for your AI agents — it talks with you, crafts high-quality briefs, and delivers them straight into Codex or Claude, then narrates their progress.")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .lineSpacing(2)

        // Boxed danger warning
        Text("Jarvis asks for approval before delegating sensitive requests, but the agent apps act autonomously once briefed. You are responsible for what they do on your system.")
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(.white.opacity(0.55))
          .multilineTextAlignment(.center)
          .lineSpacing(3)
          .padding(.horizontal, 16)
          .padding(.vertical, 14)
          .frame(maxWidth: .infinity)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(Color.white.opacity(0.05))
              .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                  .stroke(Color.white.opacity(0.06), lineWidth: 1)
              )
          )
      }
    } action: {
      EmptyView()
    }
  }

  // MARK: - Step 1: API Key

  private var apiKeyCard: some View {
    CardLayout(accentColor: Color(red: 1, green: 0.8, blue: 0.3)) {
      KeyAnimation(saved: model.settings.hasApiKey)
    } content: {
      VStack(spacing: 10) {
        Text("Connect to OpenAI")
          .font(.system(size: 22, weight: .bold))

        Text("Jarvis uses OpenAI's Realtime voice API, which requires a platform API key — a ChatGPT subscription or OAuth sign-in cannot be used. Voice usage is billed to your OpenAI API account.")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .lineSpacing(2)
      }
    } action: {
      VStack(spacing: 8) {
        HStack(spacing: 8) {
          SecureField("sk-...", text: $model.apiKeyDraft)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                  RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
            )

          Button {
            Task { await model.saveApiKey() }
          } label: {
            Text("Save")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(.black)
              .padding(.horizontal, 14)
              .padding(.vertical, 8)
              .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                  .fill(.white.opacity(0.85))
              )
          }
          .buttonStyle(.plain)
        }

        if model.settings.hasApiKey {
          apiKeyValidationStatus
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
      }
      .padding(.horizontal, 40)
      .task {
        if model.settings.hasApiKey && model.apiKeyValidation == .unknown {
          await model.validateApiKey()
        }
      }
    }
  }

  @ViewBuilder
  private var apiKeyValidationStatus: some View {
    switch model.apiKeyValidation {
    case .checking:
      HStack(spacing: 5) {
        ProgressView()
          .controlSize(.mini)
        Text("Verifying key with OpenAI…")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
    case .valid:
      HStack(spacing: 4) {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 11))
          .foregroundStyle(.green)
        Text("API key verified — Realtime access confirmed")
          .font(.system(size: 11))
          .foregroundStyle(.green.opacity(0.7))
      }
    case .invalid(let reason):
      HStack(alignment: .top, spacing: 4) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 11))
          .foregroundStyle(.orange)
        Text(reason)
          .font(.system(size: 11))
          .foregroundStyle(.orange.opacity(0.85))
          .multilineTextAlignment(.leading)
      }
    case .unknown:
      HStack(spacing: 4) {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 11))
          .foregroundStyle(.green)
        Text("API key saved")
          .font(.system(size: 11))
          .foregroundStyle(.green.opacity(0.7))
      }
    }
  }

  // MARK: - Step 2: Hotkey

  private var currentHotkey: String {
    model.settings.hotkey.isEmpty ? "Option+Space" : model.settings.hotkey
  }

  private var hotkeyCard: some View {
    CardLayout(accentColor: Color(red: 0.4, green: 0.7, blue: 1)) {
      HotkeyAnimation(hotkey: currentHotkey)
    } content: {
      VStack(spacing: 10) {
        Text("Your Hotkey")
          .font(.system(size: 22, weight: .bold))

        Text("Hold the hotkey to talk to Jarvis, release to send. You can change this anytime from the menu bar.")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .lineSpacing(2)
      }
    } action: {
      VStack(spacing: 12) {
        HStack(spacing: 12) {
          Text(GlobalHotKeyController.displayString(for: currentHotkey))
            .font(.system(size: 16, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                  RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
            )

          Menu {
            Button("\u{2325}Space") {
              model.hotkeyDraft = "Option+Space"
              Task { await model.saveHotkey() }
            }
            Button("\u{2318}\u{21E7}J") {
              model.hotkeyDraft = "Command+Shift+J"
              Task { await model.saveHotkey() }
            }
            Button("\u{2303}Space") {
              model.hotkeyDraft = "Control+Space"
              Task { await model.saveHotkey() }
            }
            Button("\u{2318}\u{21E7}Space") {
              model.hotkeyDraft = "Command+Shift+Space"
              Task { await model.saveHotkey() }
            }
            Button("F5") {
              model.hotkeyDraft = "F5"
              Task { await model.saveHotkey() }
            }
          } label: {
            HStack(spacing: 4) {
              Text("Change")
                .font(.system(size: 12, weight: .semibold))
              Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))
            )
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
        }
      }
    }
  }

  // MARK: - Step 3: Microphone

  private var microphoneCard: some View {
    PermissionCard(
      animation: { WaveformAnimation() },
      accentColor: Color(red: 0.3, green: 0.9, blue: 0.5),
      header: "Enable Microphone",
      explanation: "Jarvis needs microphone access to hear your voice commands. Audio is streamed directly to OpenAI and is never stored locally.",
      granted: model.permissions.microphone == "granted",
      grantAction: { Task { await model.requestMicrophonePermission() } }
    )
  }

  // MARK: - Step 4: Screen Recording

  private var screenRecordingCard: some View {
    PermissionCard(
      animation: { ScreenScanAnimation() },
      accentColor: .cyan,
      header: "Allow Screen Recording",
      explanation: "Jarvis captures screenshots to understand what's on your screen, so it can take the right actions in context.",
      granted: model.permissions.screen == "granted",
      grantAction: { Task { await model.requestScreenPermission() } }
    )
  }

  // MARK: - Step 5: Accessibility

  private var accessibilityCard: some View {
    PermissionCard(
      animation: { CursorClickAnimation() },
      accentColor: Color(red: 0.7, green: 0.5, blue: 1),
      header: "Grant Accessibility",
      explanation: "Jarvis needs Accessibility permission to deliver prompts into the agent apps — focusing their text box, pasting the brief, and reading their progress.",
      granted: model.permissions.accessibilityTrusted,
      grantAction: { Task { await model.requestAccessibilityPermission() } }
    )
  }

  // MARK: - Step 6: Files access

  private var filesAccessCard: some View {
    PermissionCard(
      animation: { CursorClickAnimation() },
      accentColor: Color(red: 0.35, green: 0.78, blue: 0.6),
      header: "Allow File Access",
      explanation: "Jarvis opens the files your agents produce — PDFs, Word docs, presentations — and shows them to you. macOS will ask for access to your Documents folder, where Codex and Claude save their results.",
      granted: model.documentsAccessGranted,
      grantAction: { Task { await model.requestDocumentsAccess() } }
    )
  }
}

// MARK: - Card Layout

private struct CardLayout<Animation: View, Content: View, Action: View>: View {
  let accentColor: Color
  @ViewBuilder let animation: Animation
  @ViewBuilder let content: Content
  @ViewBuilder let action: Action

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(
            RadialGradient(
              colors: [accentColor.opacity(0.05), Color.clear],
              center: .center,
              startRadius: 10,
              endRadius: 130
            )
          )
          .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
              .stroke(Color.white.opacity(0.04), lineWidth: 1)
          )

        animation
      }
      .frame(height: 180)
      .padding(.horizontal, 32)
      .padding(.top, 24)

      content
        .padding(.horizontal, 40)
        .padding(.top, 24)

      action
        .padding(.top, 14)

      Spacer(minLength: 0)
    }
  }
}

// MARK: - Permission Card

private struct PermissionCard<Animation: View>: View {
  @ViewBuilder let animation: Animation
  let accentColor: Color
  let header: String
  let explanation: String
  let granted: Bool
  let grantAction: () -> Void

  var body: some View {
    CardLayout(accentColor: accentColor) {
      animation
    } content: {
      VStack(spacing: 10) {
        Text(header)
          .font(.system(size: 22, weight: .bold))

        Text(explanation)
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .lineSpacing(2)
      }
    } action: {
      VStack(spacing: 10) {
        if !granted {
          Button(action: grantAction) {
            HStack(spacing: 6) {
              Image(systemName: "lock.open")
                .font(.system(size: 11, weight: .semibold))
              Text("Grant Permission")
                .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .background(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.85))
            )
          }
          .buttonStyle(.plain)
        }

        HStack(spacing: 5) {
          Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
            .font(.system(size: 12))
            .foregroundStyle(granted ? .green : Color.white.opacity(0.3))

          Text(granted ? "Permission Granted" : "Not yet granted")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(granted ? .green.opacity(0.7) : .secondary)
        }
        .animation(.easeOut(duration: 0.25), value: granted)
      }
    }
  }
}

// MARK: - Animated Illustrations

// Step 0: Real logo with pulsing rings
private struct WelcomeLogoAnimation: View {
  @State private var isPulsing = false

  var body: some View {
    ZStack {
      ForEach(0..<3, id: \.self) { ring in
        Circle()
          .stroke(Color.white.opacity(0.06), lineWidth: 1.5)
          .frame(width: 70 + CGFloat(ring) * 36, height: 70 + CGFloat(ring) * 36)
          .scaleEffect(isPulsing ? 1.4 : 0.85)
          .opacity(isPulsing ? 0 : 0.6)
          .animation(
            .easeOut(duration: 2.8)
              .repeatForever(autoreverses: false)
              .delay(Double(ring) * 0.55),
            value: isPulsing
          )
      }

      logoImage
    }
    .onAppear { isPulsing = true }
  }

  private var logoImage: some View {
    Group {
      if let url = AppIdentity.resourceBundle.url(forResource: "JarvisLogoTransparent", withExtension: "png"),
         let nsImage = NSImage(contentsOf: url) {
        Image(nsImage: nsImage)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 80, height: 80)
          .shadow(color: .white.opacity(0.08), radius: 16)
      } else {
        Text("J")
          .font(.system(size: 56, weight: .heavy, design: .rounded))
          .foregroundStyle(.white.opacity(0.85))
          .shadow(color: .white.opacity(0.1), radius: 16)
      }
    }
  }
}

// Step 1: Animated key icon
private struct KeyAnimation: View {
  let saved: Bool
  @State private var rotation: Double = 0
  @State private var appeared = false

  var body: some View {
    ZStack {
      Circle()
        .fill(Color(red: 1, green: 0.8, blue: 0.3).opacity(0.06))
        .frame(width: 90, height: 90)
        .scaleEffect(appeared ? 1 : 0.8)

      Image(systemName: saved ? "checkmark.seal.fill" : "key.fill")
        .font(.system(size: 40, weight: .medium))
        .foregroundStyle(
          saved
            ? Color.green.opacity(0.8)
            : Color(red: 1, green: 0.8, blue: 0.3).opacity(0.7)
        )
        .rotationEffect(.degrees(saved ? 0 : rotation))
        .scaleEffect(saved ? 1.1 : 1)
    }
    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: saved)
    .onAppear {
      withAnimation(.easeInOut(duration: 0.5)) { appeared = true }
      withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
        rotation = 15
      }
    }
  }
}

// Step 2: Animated keycap showing the hotkey
private struct HotkeyAnimation: View {
  let hotkey: String
  @State private var isPressing = false

  var body: some View {
    VStack(spacing: 6) {
      Text(GlobalHotKeyController.displayString(for: hotkey))
        .font(.system(size: 30, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(isPressing ? 0.1 : 0.05))
            .overlay(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(isPressing ? 0.2 : 0.1), lineWidth: 1.5)
            )
            .shadow(color: Color(red: 0.4, green: 0.7, blue: 1).opacity(isPressing ? 0.15 : 0), radius: 12)
        )
        .scaleEffect(isPressing ? 0.95 : 1)
        .offset(y: isPressing ? 2 : 0)

      Text("hold to talk")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(0.25))
    }
    .onAppear {
      withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
        isPressing = true
      }
    }
  }
}

// Step 3: Waveform bars
private struct WaveformAnimation: View {
  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
      Canvas { context, size in
        let time = timeline.date.timeIntervalSinceReferenceDate
        let barCount = 7
        let barWidth: CGFloat = 5
        let gap: CGFloat = 5
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
        let startX = (size.width - totalWidth) / 2
        let maxHeight = size.height * 0.5
        let minHeight: CGFloat = 8

        for i in 0..<barCount {
          let wave = sin(time * 3.2 + Double(i) * 0.7) * 0.5 + 0.5
          let secondary = sin(time * 2.1 + Double(i) * 1.1) * 0.3 + 0.5
          let combined = wave * 0.7 + secondary * 0.3
          let height = minHeight + (maxHeight - minHeight) * combined
          let x = startX + CGFloat(i) * (barWidth + gap)
          let y = (size.height - height) / 2
          let rect = CGRect(x: x, y: y, width: barWidth, height: height)
          let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)

          let brightness = 0.5 + combined * 0.35
          context.fill(path, with: .color(Color(red: 0.3 * brightness, green: 0.9 * brightness, blue: 0.5 * brightness)))
        }
      }
    }
    .frame(width: 120, height: 80)
  }
}

// Step 4: Screen with scan line
private struct ScreenScanAnimation: View {
  @State private var scanY: CGFloat = 0

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.white.opacity(0.15), lineWidth: 1.5)
        .frame(width: 110, height: 76)

      VStack(spacing: 8) {
        ForEach(0..<4, id: \.self) { i in
          RoundedRectangle(cornerRadius: 2)
            .fill(Color.white.opacity(0.06))
            .frame(width: CGFloat([70, 86, 56, 72][i]), height: 4)
        }
      }

      Rectangle()
        .fill(
          LinearGradient(
            colors: [.clear, .cyan.opacity(0.5), .clear],
            startPoint: .leading,
            endPoint: .trailing
          )
        )
        .frame(width: 108, height: 2)
        .offset(y: -36 + scanY * 72)

      RoundedRectangle(cornerRadius: 2)
        .fill(Color.white.opacity(0.08))
        .frame(width: 40, height: 4)
        .offset(y: 46)
    }
    .onAppear {
      withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
        scanY = 1
      }
    }
  }
}

// Step 5: Cursor with click ripple
private struct CursorClickAnimation: View {
  @State private var isClicking = false

  var body: some View {
    ZStack {
      ForEach(0..<3, id: \.self) { ring in
        Circle()
          .stroke(Color(red: 0.7, green: 0.5, blue: 1).opacity(0.2), lineWidth: 1.5)
          .frame(width: 16, height: 16)
          .scaleEffect(isClicking ? 4.5 - CGFloat(ring) * 0.6 : 1)
          .opacity(isClicking ? 0 : 0.5)
          .animation(
            .easeOut(duration: 1.8)
              .repeatForever(autoreverses: false)
              .delay(Double(ring) * 0.35),
            value: isClicking
          )
      }

      Image(systemName: "cursorarrow")
        .font(.system(size: 36, weight: .regular))
        .foregroundStyle(.white.opacity(0.75))
        .offset(x: -4, y: -4)
        .shadow(color: Color(red: 0.7, green: 0.5, blue: 1).opacity(0.2), radius: 8)
    }
    .onAppear { isClicking = true }
  }
}
