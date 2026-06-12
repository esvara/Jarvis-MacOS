import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
  private static let statusBarIconResourceName = "JarveyStatusBarIcon"

  private let statusItem: NSStatusItem
  private let popover: NSPopover
  private let model: AppModel
  private let onShowControlCenter: () -> Void

  init(model: AppModel, onShowControlCenter: @escaping () -> Void = {}) {
    self.model = model
    self.onShowControlCenter = onShowControlCenter
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    popover = NSPopover()

    super.init()

    if let button = statusItem.button {
      button.image = statusBarIcon() ?? NSImage(
        systemSymbolName: "square.grid.3x3.fill",
        accessibilityDescription: "Jarvis"
      )
      button.imageScaling = .scaleProportionallyDown
      button.action = #selector(togglePopover)
      button.target = self
    }

    let hostingController = NSHostingController(
      rootView: StatusBarSettingsView(
        model: model,
        onShowControlCenter: onShowControlCenter
      )
    )
    popover.contentViewController = hostingController
    popover.behavior = .transient
    popover.contentSize = NSSize(width: 340, height: 560)
    popover.appearance = NSAppearance(named: .darkAqua)
  }

  func showPopover() {
    guard let button = statusItem.button else { return }
    model.refreshPermissions(force: true)
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
  }

  private func statusBarIcon() -> NSImage? {
    guard
      let url = Bundle.main.url(
        forResource: Self.statusBarIconResourceName,
        withExtension: "png"
      ),
      let image = NSImage(contentsOf: url)
    else {
      return nil
    }

    image.isTemplate = true
    image.size = NSSize(width: 18, height: 18)
    return image
  }

  @objc private func togglePopover() {
    if popover.isShown {
      popover.performClose(nil)
    } else {
      showPopover()
    }
  }
}

// MARK: - Settings View

private struct VoiceOption: Identifiable {
  let id: String
  let name: String
  let detail: String
}

private struct VoiceModeOption: Identifiable {
  let id: String
  let name: String
  let detail: String
}

private struct StatusBarSettingsView: View {
  @ObservedObject var model: AppModel
  let onShowControlCenter: () -> Void
  @State private var selectedTab: SettingsTab = .general

  private static let realtimeVoices: [VoiceOption] = [
    VoiceOption(id: "cedar", name: "Cedar", detail: "Deep, natural (default)"),
    VoiceOption(id: "marin", name: "Marin", detail: "Warm, natural"),
    VoiceOption(id: "alloy", name: "Alloy", detail: "Balanced"),
    VoiceOption(id: "ash", name: "Ash", detail: "Calm"),
    VoiceOption(id: "ballad", name: "Ballad", detail: "Expressive"),
    VoiceOption(id: "coral", name: "Coral", detail: "Bright"),
    VoiceOption(id: "echo", name: "Echo", detail: "Clear"),
    VoiceOption(id: "sage", name: "Sage", detail: "Grounded"),
    VoiceOption(id: "shimmer", name: "Shimmer", detail: "Light"),
    VoiceOption(id: "verse", name: "Verse", detail: "Smooth")
  ]

  private static let voiceInputModes: [VoiceModeOption] = [
    VoiceModeOption(id: "push_to_talk", name: "Hold to Talk", detail: "Hotkey sends on release"),
    VoiceModeOption(id: "continuous", name: "Always Listening", detail: "Keeps mic open"),
    VoiceModeOption(id: "manual", name: "Manual", detail: "Use Listen and Mute")
  ]

  private enum SettingsTab: String, CaseIterable {
    case general = "General"
    case permissions = "Permissions"
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      tabBar
      Divider().opacity(0.3)

      ScrollView {
        VStack(spacing: 0) {
          switch selectedTab {
          case .general:
            generalTab
          case .permissions:
            permissionsTab
          }
        }
        .padding(16)
      }

      Spacer(minLength: 0)
      footerControls
    }
    .frame(width: 340, height: 560)
    .task {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await model.refreshStatus()
      }
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 10) {
      ZStack {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.white.opacity(0.06))
          .frame(width: 32, height: 32)

        if let url = AppIdentity.resourceBundle.url(forResource: "JarveyLogoTransparent", withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
          Image(nsImage: nsImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 20, height: 20)
        } else {
          Image(systemName: "square.grid.3x3.fill")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.8))
        }
      }

      VStack(alignment: .leading, spacing: 1) {
        Text("Jarvis")
          .font(.system(size: 14, weight: .semibold))

        HStack(spacing: 5) {
          Circle()
            .fill(statusColor)
            .frame(width: 6, height: 6)

          Text(statusLabel)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
      }

      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private var statusLabel: String {
    if !model.sidecarReady { return "Offline" }
    if model.voiceState.connected {
      return model.phase == "idle" ? "Connected" : model.phase.capitalized
    }
    return model.hasBlockingSetupIssue ? "Setup Required" : "Ready"
  }

  private var statusColor: Color {
    switch model.phase {
    case "error": return .red
    case "approvals": return .yellow
    case "speaking", "listening", "thinking", "acting", "connecting": return .cyan
    default:
      if !model.sidecarReady { return Color(white: 0.4) }
      return model.voiceState.connected ? .green : Color(white: 0.55)
    }
  }

  // MARK: - Tab Bar

  private var tabBar: some View {
    HStack(spacing: 2) {
      ForEach(SettingsTab.allCases, id: \.self) { tab in
        Button {
          withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
        } label: {
          Text(tab.rawValue)
            .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
            .foregroundStyle(selectedTab == tab ? .white : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selectedTab == tab ? Color.white.opacity(0.08) : .clear)
            )
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 8)
  }

  // MARK: - General Tab

  private var generalTab: some View {
    VStack(spacing: 16) {
      // Hotkey
      SettingsCard {
        VStack(alignment: .leading, spacing: 8) {
          SettingsSectionHeader(title: "Hotkey", icon: "keyboard")

          HStack {
            Text(GlobalHotKeyController.displayString(for: model.settings.hotkey.isEmpty ? "Option+Space" : model.settings.hotkey))
              .font(.system(size: 13, weight: .medium, design: .rounded))
              .foregroundStyle(.white.opacity(0.8))
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                  .fill(Color.white.opacity(0.06))
                  .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                      .stroke(Color.white.opacity(0.08), lineWidth: 1)
                  )
              )

            Spacer()

            Menu {
              Button("\u{2325}Space (Option+Space)") {
                model.hotkeyDraft = "Option+Space"
                Task { await model.saveHotkey() }
              }
              Button("\u{2318}\u{21E7}J (Cmd+Shift+J)") {
                model.hotkeyDraft = "Command+Shift+J"
                Task { await model.saveHotkey() }
              }
              Button("\u{2303}Space (Ctrl+Space)") {
                model.hotkeyDraft = "Control+Space"
                Task { await model.saveHotkey() }
              }
              Button("\u{2318}\u{21E7}Space (Cmd+Shift+Space)") {
                model.hotkeyDraft = "Command+Shift+Space"
                Task { await model.saveHotkey() }
              }
              Button("F5") {
                model.hotkeyDraft = "F5"
                Task { await model.saveHotkey() }
              }
            } label: {
              Text("Change")
                .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
          }

          Text("Hold to talk, release to send")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
      }

      // API Key
      SettingsCard {
        VStack(alignment: .leading, spacing: 8) {
          SettingsSectionHeader(title: "OpenAI API Key", icon: "key")

          HStack(spacing: 6) {
            SecureField("sk-...", text: $model.apiKeyDraft)
              .textFieldStyle(.plain)
              .font(.system(size: 12, design: .monospaced))
              .padding(.horizontal, 8)
              .padding(.vertical, 6)
              .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                  .fill(Color.white.opacity(0.04))
                  .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                      .stroke(Color.white.opacity(0.08), lineWidth: 1)
                  )
              )

            Button {
              Task { await model.saveApiKey() }
            } label: {
              Text("Save")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                  RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.1))
                )
            }
            .buttonStyle(.plain)
          }

          Text(model.settings.hasApiKey ? "API key configured locally" : "No API key configured")
            .font(.system(size: 10))
            .foregroundStyle(model.settings.hasApiKey ? .green.opacity(0.8) : .secondary)
        }
      }

      // Voice Controls
      SettingsCard {
        VStack(alignment: .leading, spacing: 10) {
          SettingsSectionHeader(title: "Voice", icon: "waveform")

          settingsMenuRow(
            title: "Voice",
            value: voiceName(for: model.settings.voice),
            icon: "speaker.wave.2"
          ) {
            ForEach(Self.realtimeVoices) { voice in
              Button {
                Task { await model.saveVoice(voice.id) }
              } label: {
                menuSelectionLabel(
                  title: "\(voice.name) · \(voice.detail)",
                  selected: model.settings.voice == voice.id
                )
              }
            }
          }

          settingsMenuRow(
            title: "Mode",
            value: voiceModeName(for: model.voiceInputMode),
            icon: "mic"
          ) {
            ForEach(Self.voiceInputModes) { mode in
              Button {
                Task { await model.saveVoiceInputMode(mode.id) }
              } label: {
                menuSelectionLabel(
                  title: "\(mode.name) · \(mode.detail)",
                  selected: model.voiceInputMode == mode.id
                )
              }
            }
          }

          HStack(spacing: 6) {
            if model.voiceState.connected {
              SettingsActionButton(
                title: model.voiceState.muted ? "Listen" : "Mute",
                style: model.voiceState.muted ? .primary : .secondary
              ) {
                Task { await model.toggleListeningFromSettings() }
              }
              SettingsActionButton(title: "Disconnect", style: .secondary) {
                Task { await model.disconnectVoice() }
              }
            } else {
              SettingsActionButton(
                title: model.phase == "connecting" ? "Connecting..." : "Connect Voice",
                style: .primary,
                isDisabled: model.phase == "connecting"
              ) {
                Task { await model.connectVoice(startMuted: model.voiceConnectsMuted) }
              }
            }

            if model.activeTaskId != nil {
              SettingsActionButton(title: "Stop", style: .destructive) {
                Task { await model.cancelActiveTask() }
              }
            }
          }

          Text(voiceStatusLine)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(2)

          VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
              Image(systemName: model.voiceState.muted ? "mic.slash" : "mic")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(model.voiceState.muted ? Color.secondary : Color.cyan)

              GeometryReader { proxy in
                ZStack(alignment: .leading) {
                  Capsule()
                    .fill(Color.white.opacity(0.08))
                  Capsule()
                    .fill(model.voiceState.muted ? Color.white.opacity(0.16) : Color.cyan.opacity(0.75))
                    .frame(width: max(4, proxy.size.width * CGFloat(min(max(model.voiceState.level, 0), 1))))
                }
              }
              .frame(height: 6)
            }

            if let latestTranscriptLine {
              Text(latestTranscriptLine)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(2)
            }
          }

          if !model.displayErrorMessage.isEmpty {
            Text(model.displayErrorMessage)
              .font(.system(size: 11))
              .foregroundStyle(Color(red: 1, green: 0.48, blue: 0.48))
              .lineLimit(3)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func settingsMenuRow<MenuContent: View>(
    title: String,
    value: String,
    icon: String,
    @ViewBuilder content: () -> MenuContent
  ) -> some View {
    HStack(spacing: 8) {
      Image(systemName: icon)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(width: 16)

      Text(title)
        .font(.system(size: 12, weight: .medium))

      Spacer()

      Menu {
        content()
      } label: {
        HStack(spacing: 4) {
          Text(value)
            .font(.system(size: 11, weight: .semibold))
          Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 8, weight: .semibold))
        }
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
    .padding(.vertical, 2)
  }

  private func menuSelectionLabel(title: String, selected: Bool) -> some View {
    HStack {
      if selected {
        Image(systemName: "checkmark")
      }
      Text(title)
    }
  }

  private var voiceStatusLine: String {
    if model.phase == "connecting" {
      return "Connecting to GPT Realtime 2."
    }
    if model.voiceState.connected && !model.voiceState.muted {
      return model.voiceInputMode == "continuous" ? "Connected. Microphone stays open." : "Connected and listening."
    }
    if model.voiceState.connected {
      return "Connected. Microphone is muted."
    }
    return model.voiceInputMode == "continuous" ? "Connect to start continuous listening." : "Connect to warm up voice."
  }

  private var latestTranscriptLine: String? {
    guard let entry = model.transcript.last else {
      return nil
    }
    let speaker = entry.role == "user" ? "You" : "Jarvis"
    let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      return nil
    }
    return "\(speaker): \(text)"
  }

  private func voiceName(for id: String) -> String {
    Self.realtimeVoices.first(where: { $0.id == id })?.name ?? id
  }

  private func voiceModeName(for id: String) -> String {
    Self.voiceInputModes.first(where: { $0.id == id })?.name ?? "Hold to Talk"
  }

  // MARK: - Permissions Tab

  private var permissionsTab: some View {
    VStack(spacing: 12) {
      SettingsCard {
        VStack(spacing: 2) {
          PermissionRow(
            name: "Microphone",
            icon: "mic",
            granted: model.permissions.microphone == "granted",
            status: model.permissions.microphone
          ) { Task { await model.requestMicrophonePermission() } }

          thinDivider

          PermissionRow(
            name: "Screen Recording",
            icon: "rectangle.dashed.badge.record",
            granted: model.permissions.screen == "granted",
            status: model.permissions.screen
          ) { Task { await model.requestScreenPermission() } }

          thinDivider

          PermissionRow(
            name: "Accessibility",
            icon: "accessibility",
            granted: model.permissions.accessibilityTrusted,
            status: model.permissions.accessibilityTrusted ? "granted" : "missing"
          ) { Task { await model.requestAccessibilityPermission() } }
        }
      }

      SettingsCard {
        VStack(spacing: 2) {
          PermissionRow(
            name: "Input Server",
            icon: "server.rack",
            granted: model.health.inputServerAvailable,
            status: model.health.inputServerAvailable
              ? (model.health.inputServerVersion ?? "running") : "offline"
          ) { Task { await model.refresh() } }

          thinDivider

          PermissionRow(
            name: "Sidecar",
            icon: "gearshape.2",
            granted: model.sidecarReady,
            status: model.sidecarReady ? "running" : "offline"
          ) { Task { await model.refresh() } }

          thinDivider

          PermissionRow(
            name: "Voice Runtime",
            icon: "waveform.badge.mic",
            granted: model.permissions.voiceRuntimeSupported,
            status: model.permissions.voiceRuntimeSupported ? "supported" : "unsupported"
          ) { model.refreshPermissions(force: true) }
        }
      }

      Button {
        Task { await model.requestPermissions() }
      } label: {
        Text("Grant All Permissions")
          .font(.system(size: 12, weight: .medium))
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(Color.white.opacity(0.06))
          )
      }
      .buttonStyle(.plain)
    }
  }

  private var thinDivider: some View {
    Rectangle()
      .fill(Color.white.opacity(0.05))
      .frame(height: 1)
      .padding(.horizontal, 4)
  }

  // MARK: - Footer

  private var footerControls: some View {
    HStack {
      Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
        .font(.system(size: 10))
        .foregroundStyle(Color(white: 0.4))

      Spacer()

      Button {
        onShowControlCenter()
      } label: {
        Text("Control Center")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)

      Button {
        NSApplication.shared.terminate(nil)
      } label: {
        Text("Quit")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .overlay(alignment: .top) {
      Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
    }
  }
}

// MARK: - Reusable Components

private struct SettingsCard<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    content
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color.white.opacity(0.04))
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(Color.white.opacity(0.05), lineWidth: 1)
          )
      )
  }
}

private struct SettingsSectionHeader: View {
  let title: String
  let icon: String

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: icon)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)

      Text(title.uppercased())
        .font(.system(size: 10, weight: .bold))
        .tracking(0.5)
        .foregroundStyle(.secondary)
    }
  }
}

private struct SettingsActionButton: View {
  enum Style { case primary, secondary, destructive }

  let title: String
  var style: Style = .secondary
  var isDisabled = false
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(isDisabled ? .secondary : foregroundColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(backgroundColor)
        )
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .onHover { isHovered = $0 }
  }

  private var foregroundColor: Color {
    switch style {
    case .primary: return .black
    case .secondary: return .white.opacity(0.8)
    case .destructive: return Color(red: 1, green: 0.48, blue: 0.48)
    }
  }

  private var backgroundColor: Color {
    switch style {
    case .primary: return .white.opacity(isHovered ? 0.95 : 0.85)
    case .secondary: return .white.opacity(isHovered ? 0.12 : 0.07)
    case .destructive: return Color.red.opacity(isHovered ? 0.2 : 0.12)
    }
  }
}

private struct PermissionRow: View {
  let name: String
  let icon: String
  let granted: Bool
  let status: String
  let action: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: icon)
        .font(.system(size: 11))
        .foregroundStyle(granted ? .green : .secondary)
        .frame(width: 16)

      Text(name)
        .font(.system(size: 12, weight: .medium))

      Spacer()

      Text(status.uppercased())
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundStyle(granted ? Color.green.opacity(0.6) : .secondary)

      if !granted {
        Button("Fix", action: action)
          .font(.system(size: 10, weight: .semibold))
          .buttonStyle(.plain)
          .foregroundStyle(.cyan)
      }
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 4)
  }
}
