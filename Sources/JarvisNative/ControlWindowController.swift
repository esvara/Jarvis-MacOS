import AppKit
import SwiftUI

@MainActor
final class ControlWindowController: NSObject, NSWindowDelegate {
  private let model: AppModel
  private var window: NSWindow?

  init(model: AppModel) {
    self.model = model
    super.init()
  }

  func show() {
    if let window {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let view = ControlCenterView(model: model)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "Jarvis Control Center"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true
    window.backgroundColor = NSColor(white: 0.06, alpha: 1)
    window.appearance = NSAppearance(named: .darkAqua)
    window.minSize = NSSize(width: 820, height: 560)
    window.contentViewController = NSHostingController(rootView: view)
    window.delegate = self
    window.center()
    window.isReleasedWhenClosed = false
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    self.window = window

    Task {
      await model.refresh()
    }
  }

  func windowWillClose(_ notification: Notification) {
    window = nil
  }
}

private struct ControlCenterView: View {
  @ObservedObject var model: AppModel
  @State private var selectedPanel: ControlPanel = .console

  private enum ControlPanel: String, CaseIterable {
    case console = "Console"
    case system = "System"
  }

  var body: some View {
    VStack(spacing: 0) {
      header

      HStack(spacing: 0) {
        sidebar
        Rectangle()
          .fill(Color.white.opacity(0.06))
          .frame(width: 1)
        content
      }
    }
    .frame(minWidth: 960, minHeight: 600)
    .background(Color(white: 0.06))
    .environment(\.colorScheme, .dark)
    .task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        await model.refreshStatus()
      }
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Jarvis")
          .font(.system(size: 18, weight: .semibold))
        Text(model.compactStatus)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 12)

      // Degrade gracefully on narrow windows: drop the status pills first,
      // then the button titles — the actions must never overflow the margin.
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          headerPills
          headerButtons(compact: false)
        }
        headerButtons(compact: false)
        headerButtons(compact: true)
      }
    }
    .padding(.horizontal, 28)
    .padding(.top, 24)
    .padding(.bottom, 16)
  }

  private var headerPills: some View {
    HStack(spacing: 12) {
      StatusPill(label: model.phase.capitalized, color: phaseColor)
      StatusPill(label: model.voiceState.connected ? "Voice On" : "Voice Off", color: model.voiceState.connected ? .green : .secondary)
      StatusPill(label: model.health.inputServerAvailable ? "Local Control" : "No Control", color: model.health.inputServerAvailable ? .cyan : .red)
    }
  }

  private func headerButtons(compact: Bool) -> some View {
    HStack(spacing: 12) {
      Button {
        Task { await model.refresh() }
      } label: {
        if compact {
          Image(systemName: "arrow.clockwise")
        } else {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
      }
      .buttonStyle(ControlButtonStyle())
      .help("Refresh")

      Button {
        Task { await model.stopAllActivity() }
      } label: {
        if compact {
          Image(systemName: "stop.fill")
        } else {
          Label("Stop All", systemImage: "stop.fill")
        }
      }
      .buttonStyle(ControlButtonStyle(kind: .danger))
      .help("Stop All")
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(ControlPanel.allCases, id: \.self) { panel in
        Button {
          selectedPanel = panel
        } label: {
          HStack(spacing: 9) {
            Image(systemName: icon(for: panel))
              .frame(width: 18)
            Text(panel.rawValue)
              .font(.system(size: 13, weight: .medium))
            Spacer()
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 9)
          .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .fill(selectedPanel == panel ? Color.white.opacity(0.09) : .clear)
          )
        }
        .buttonStyle(.plain)
      }

      Spacer()

      VStack(alignment: .leading, spacing: 8) {
        SmallMetric(label: "Active Task", value: model.activeTaskId == nil ? "None" : shortId(model.activeTaskId))
        SmallMetric(label: "Runtime", value: model.runtimeHeartbeatLabel)
        SmallMetric(label: "Voice", value: model.voiceState.muted ? "Muted" : "Listening")
      }
    }
    .padding(16)
    .frame(width: 180)
  }

  @ViewBuilder
  private var content: some View {
    switch selectedPanel {
    case .console:
      consolePanel
    case .system:
      systemPanel
    }
  }

  private var consolePanel: some View {
    // Three columns: compact voice controls | transcript (the primary
    // content, full height) | status stack. The transcript used to sit
    // squeezed under the voice card where it was effectively hidden.
    HStack(spacing: 16) {
      VStack(spacing: 14) {
        ControlCard(title: "Voice Operator", icon: "waveform") {
          VStack(spacing: 12) {
            VoiceWaveView(
              phase: model.phase,
              level: model.voiceState.level,
              connected: model.voiceState.connected,
              muted: model.voiceState.muted
            )
            .frame(height: 96)

            VStack(spacing: 3) {
              Text(voiceTitle)
                .font(.system(size: 16, weight: .semibold))
              Text(voiceSubtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            }

            HStack(spacing: 12) {
              VoiceModeButton(
                title: model.voiceState.connected ? "End" : "Connect",
                icon: model.voiceState.connected ? "phone.down.fill" : "phone.fill",
                kind: model.voiceState.connected ? .danger : .primary
              ) {
                Task {
                  if model.voiceState.connected {
                    await model.disconnectVoice()
                  } else {
                    await model.connectVoice(startMuted: model.voiceConnectsMuted)
                  }
                }
              }

              VoiceModeButton(
                title: model.voiceState.muted ? "Muted" : "Listening",
                icon: model.voiceState.muted ? "mic.slash.fill" : "mic.fill",
                kind: model.voiceState.connected ? (model.voiceState.muted ? .danger : .success) : .neutral
              ) {
                Task { await model.toggleListeningFromSettings() }
              }
              .disabled(!model.voiceState.connected)

              VoiceModeButton(title: "Stop", icon: "stop.fill", kind: .neutral) {
                Task { await model.interruptVoice() }
              }
              .disabled(!model.voiceState.connected)
            }

            HStack(spacing: 8) {
              Image(systemName: "globe")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
              Text("Language")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
              ExecutionModeButton(title: "Español", selected: model.assistantLanguage == "es") {
                Task { await model.saveAssistantLanguage("es") }
              }
              ExecutionModeButton(title: "English", selected: model.assistantLanguage == "en") {
                Task { await model.saveAssistantLanguage("en") }
              }
            }

            if !model.displayErrorMessage.isEmpty {
              Text(model.displayErrorMessage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(red: 1, green: 0.48, blue: 0.48))
                .multilineTextAlignment(.center)
                .lineLimit(4)
            }
          }
        }

        if (model.settings.voiceProvider ?? "openai") == "local" {
          localVoiceCard
        }

        Spacer(minLength: 0)
      }
      .frame(width: 360)

      // One hero surface: the agents strip on top, an actionable approval
      // banner when pending, and a single chronological feed merging the
      // transcript with backend events (both carry ISO timestamps).
      liveActivityCard
    }
    .padding(18)
  }

  /// Everything that happens, in one place: transcript, notifications,
  /// approvals, agent deliveries. Transcript entries and backend events are
  /// interleaved chronologically.
  private var liveActivityCard: some View {
    ControlCard(title: "Live Activity", icon: "list.bullet.rectangle") {
      VStack(alignment: .leading, spacing: 10) {
        agentsStrip

        if model.activeTaskId != nil {
          activeTaskStrip
        }

        approvalBanner

        Rectangle()
          .fill(Color.white.opacity(0.06))
          .frame(height: 1)

        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
              if activityFeed.isEmpty {
                Text("Nothing yet — connect and start talking.")
                  .font(.system(size: 13))
                  .foregroundStyle(.secondary)
                  .padding(.top, 8)
              } else {
                ForEach(activityFeed) { item in
                  switch item {
                  case .transcript(let entry):
                    TranscriptRow(entry: entry)
                      .id(item.id)
                  case .event(let event):
                    EventRow(event: event, summary: model.statusLine(for: event))
                      .id(item.id)
                  }
                }
              }
            }
            .padding(.vertical, 2)
          }
          .onChange(of: activityFeed.count) {
            if let last = activityFeed.last {
              withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(last.id, anchor: .bottom)
              }
            }
          }
        }
        .frame(maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private enum ActivityItem: Identifiable {
    case transcript(TranscriptEntry)
    case event(BackendEvent)

    var id: String {
      switch self {
      case .transcript(let entry): return "t-\(entry.id)"
      case .event(let event): return "e-\(event.id)"
      }
    }

    /// ISO-8601 timestamps sort correctly as plain strings.
    var sortKey: String {
      switch self {
      case .transcript(let entry): return entry.timestamp
      case .event(let event): return event.createdAt
      }
    }
  }

  private var activityFeed: [ActivityItem] {
    (model.transcript.map(ActivityItem.transcript) + model.events.map(ActivityItem.event))
      .sorted { $0.sortKey < $1.sortKey }
  }

  /// Agent status as a thin line instead of a full card: a colored dot per
  /// agent (click = read its status aloud) plus the last-delivery badge.
  private var agentsStrip: some View {
    HStack(spacing: 14) {
      if model.agentsStatus.isEmpty {
        agentDot(
          name: "Codex",
          running: model.codexStatus.codexRunning,
          installed: true,
          action: { Task { await model.readAgentPmStatus("codex") } })
      } else {
        ForEach(model.agentsStatus) { agentRow in
          agentDot(
            name: agentRow.displayName,
            running: agentRow.running,
            installed: agentRow.installed,
            action: { Task { await model.readAgentPmStatus(agentRow.agent) } })
        }
      }

      if let delivery = model.lastDeliveryBadge {
        HStack(spacing: 4) {
          Image(systemName: delivery.confirmed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 9))
            .foregroundStyle(delivery.confirmed ? .green : .orange)
          Text(delivery.label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(delivery.confirmed ? Color.green.opacity(0.8) : Color.orange.opacity(0.9))
            .lineLimit(1)
        }
      }

      Spacer()

      if !model.codexPmStatus.summary.isEmpty {
        Text(model.codexPmStatus.summary)
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .frame(maxWidth: 320, alignment: .trailing)
      }
    }
  }

  private func agentDot(name: String, running: Bool, installed: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Circle()
          .fill(running ? Color.green : (installed ? Color.orange : Color.secondary))
          .frame(width: 7, height: 7)
        Text(name)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.white.opacity(0.85))
      }
    }
    .buttonStyle(.plain)
    .disabled(!running)
    .help(running ? "Read \(name) status" : "\(name) is not running")
  }

  private var activeTaskStrip: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text("Task \(shortId(model.activeTaskId)) running")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
      Spacer()
      Button {
        Task { await model.cancelActiveTask() }
      } label: {
        Label("Stop Task", systemImage: "stop.fill")
      }
      .buttonStyle(ControlButtonStyle(kind: .danger))
    }
  }

  /// Pending approvals surface at the top of the feed as an actionable
  /// banner instead of living in their own card.
  @ViewBuilder
  private var approvalBanner: some View {
    if let approval = model.pendingApproval {
      approvalBannerBody(
        title: approval.summary,
        detail: approval.detail,
        onReject: { Task { await model.rejectPending() } },
        onApprove: { Task { await model.approvePending() } })
    } else if let approval = model.pendingRealtimeApproval {
      approvalBannerBody(
        title: approval.title,
        detail: approval.detail,
        onReject: { Task { await model.rejectRealtimeApproval() } },
        onApprove: { Task { await model.approveRealtimeApproval() } })
    }
  }

  private func approvalBannerBody(
    title: String,
    detail: String?,
    onReject: @escaping () -> Void,
    onApprove: @escaping () -> Void
  ) -> some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: "hand.raised.fill")
        .font(.system(size: 13))
        .foregroundStyle(.yellow)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(size: 12, weight: .semibold))
        if let detail, !detail.isEmpty {
          Text(detail)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      Spacer()
      Button("Reject", action: onReject)
        .buttonStyle(ControlButtonStyle(kind: .danger))
      Button("Approve", action: onApprove)
        .buttonStyle(ControlButtonStyle(kind: .primary))
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.yellow.opacity(0.08))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.yellow.opacity(0.35), lineWidth: 1)
        )
    )
  }

  private var localVoiceCard: some View {
    ControlCard(title: "Local Voice", icon: "cpu") {
      VStack(alignment: .leading, spacing: 14) {
        // Live model status: warming line, or ready badges.
        if !model.localWarmupStatus.isEmpty {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(model.localWarmupStatus)
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(.yellow.opacity(0.9))
          }
        } else {
          HStack(spacing: 10) {
            statusPill(
              label: "Model",
              ok: model.localVoiceHealth?.running == true && model.localVoiceHealth?.modelPulled == true,
              okText: "Qwen ready",
              badText: model.localVoiceHealth?.running == false ? "Ollama off" : "no model")
            if (model.settings.localSttEngine ?? "apple") == "parakeet" {
              statusPill(label: "STT", ok: model.parakeetReady, okText: "Parakeet ready", badText: "loading…")
            } else {
              statusPill(label: "STT", ok: true, okText: "Apple ready", badText: "—")
            }
          }
        }

        localVoiceRow(title: "Speech engine") {
          Picker("", selection: sttEngineBinding) {
            Text("Apple Dictation").tag("apple")
            Text("Parakeet v3").tag("parakeet")
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(width: 220)
        }

        localVoiceRow(title: "Barge-in (talk over Jarvis)") {
          Toggle("", isOn: bargeInBinding)
            .labelsHidden()
            .toggleStyle(.switch)
        }

        Text("Changes apply live. After switching the speech engine, Jarvis re-arms hands-free automatically once the model is warm.")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)

        Button {
          Task { await model.warmLocalModels() }
        } label: {
          Label("Reload / warm models", systemImage: "arrow.clockwise")
            .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.cyan.opacity(0.9))
      }
    }
  }

  private var sttEngineBinding: Binding<String> {
    Binding(
      get: { model.settings.localSttEngine ?? "apple" },
      set: { engine in Task { await model.saveLocalSttEngine(engine) } })
  }

  private var bargeInBinding: Binding<Bool> {
    Binding(
      get: { model.settings.bargeInEnabled ?? true },
      set: { on in Task { await model.saveBargeIn(on) } })
  }

  private func localVoiceRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
    HStack {
      Text(title)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.85))
      Spacer()
      content()
    }
  }

  private func statusPill(label: String, ok: Bool, okText: String, badText: String) -> some View {
    HStack(spacing: 5) {
      Circle()
        .fill(ok ? Color.green : Color.orange)
        .frame(width: 7, height: 7)
      Text("\(label): \(ok ? okText : badText)")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(ok ? .green.opacity(0.9) : .orange.opacity(0.9))
    }
  }

  private var voiceTitle: String {
    if model.phase == "connecting" {
      return "Connecting..."
    }
    if model.voiceState.connected && !model.voiceState.muted {
      return model.phase == "speaking" ? "Speaking" : "Listening"
    }
    if model.voiceState.connected {
      return "Connected"
    }
    return "Disconnected"
  }

  private var voiceSubtitle: String {
    if !model.displayErrorMessage.isEmpty {
      return "Voice needs attention"
    }
    if model.phase == "connecting" {
      return "Opening the microphone and realtime session"
    }
    if model.voiceState.connected && !model.voiceState.muted {
      return "Speak naturally; Jarvis will answer by voice"
    }
    if model.voiceState.connected {
      return "Microphone is muted"
    }
    return "Connect to start a realtime voice session"
  }


  private var systemPanel: some View {
    HStack(spacing: 16) {
      VStack(spacing: 16) {
        ControlCard(title: "Local Runtime", icon: "server.rack") {
          VStack(spacing: 10) {
            SystemRow(label: "Sidecar", value: model.sidecarReady ? "Running" : "Offline", ok: model.sidecarReady)
            SystemRow(label: "Input Server", value: model.health.inputServerAvailable ? (model.health.inputServerVersion ?? "Running") : "Offline", ok: model.health.inputServerAvailable)
            SystemRow(label: "Queue", value: model.backendQueueLabel, ok: true)
            SystemRow(label: "Heartbeat", value: model.runtimeHeartbeatLabel, ok: model.lastHeartbeatAt != nil)
            SystemRow(label: "API Key", value: model.settings.hasApiKey ? "Configured locally" : "Missing", ok: model.settings.hasApiKey)
            SystemRow(label: "Local Auth", value: model.health.secured == true ? "Secured" : "Open", ok: model.health.secured == true)
          }
        }

      }
      .frame(width: 430)

      ControlCard(title: "Permissions", icon: "lock.shield") {
        VStack(spacing: 10) {
          SystemRow(label: "Microphone", value: model.permissions.microphone, ok: model.permissions.microphone == "granted")
          SystemRow(label: "Screen Recording", value: model.permissions.screen, ok: model.permissions.screen == "granted")
          SystemRow(label: "Accessibility", value: model.permissions.accessibilityTrusted ? "granted" : "missing", ok: model.permissions.accessibilityTrusted)
          SystemRow(label: "Voice Runtime", value: model.permissions.voiceRuntimeSupported ? "supported" : "unsupported", ok: model.permissions.voiceRuntimeSupported)
          HStack {
            Spacer()
            Button {
              Task { await model.requestPermissions() }
            } label: {
              Label("Check Permissions", systemImage: "checkmark.shield")
            }
            .buttonStyle(ControlButtonStyle())
          }
        }
      }
    }
    .padding(18)
  }

  private var phaseColor: Color {
    switch model.phase {
    case "error": return .red
    case "approvals": return .yellow
    case "speaking", "listening", "thinking", "acting", "connecting": return .cyan
    default: return model.activeTaskId == nil ? .secondary : .green
    }
  }

  private func icon(for panel: ControlPanel) -> String {
    switch panel {
    case .console: return "waveform"
    case .system: return "server.rack"
    }
  }

  private func shortId(_ taskId: String?) -> String {
    guard let taskId, !taskId.isEmpty else { return "None" }
    return String(taskId.prefix(8))
  }
}

private struct ControlCard<Content: View>: View {
  let title: String
  let icon: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 7) {
        Image(systemName: icon)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)
        Text(title.uppercased())
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(.secondary)
        Spacer()
      }

      content
      Spacer(minLength: 0)
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.white.opacity(0.045))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    )
  }
}

private struct EventRow: View {
  let event: BackendEvent
  let summary: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Circle()
        .fill(color)
        .frame(width: 8, height: 8)
        .padding(.top, 5)

      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(event.type.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(.system(size: 12, weight: .semibold))
          Spacer()
          Text(timeText(event.createdAt))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
        }

        Text(summary)
          .font(.system(size: 12))
          .foregroundStyle(.white.opacity(0.78))
          .lineLimit(4)

        Text(String(event.taskId.prefix(8)))
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.secondary)
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(Color.white.opacity(0.035))
    )
  }

  private var color: Color {
    switch event.type {
    case "failed": return .red
    case "cancelled": return .orange
    case "completed": return .green
    case "approval_requested": return .yellow
    case "screenshot", "tool_started", "delegated": return .cyan
    default: return .secondary
    }
  }
}

private struct CodexEventRow: View {
  let event: CodexBridgeEvent

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Circle()
        .fill(color)
        .frame(width: 8, height: 8)
        .padding(.top, 5)

      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(event.type.capitalized)
            .font(.system(size: 12, weight: .semibold))
          Spacer()
          Text(timeText(event.createdAt))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
        }

        Text(event.summary)
          .font(.system(size: 12))
          .foregroundStyle(.white.opacity(0.78))
          .lineLimit(4)

        if let command = event.command, !command.isEmpty {
          Text(command)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(3)
        }
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(Color.white.opacity(0.035))
    )
  }

  private var color: Color {
    switch event.type {
    case "sent": return .green
    case "blocked", "error": return .red
    case "stopped": return .orange
    case "prepared": return .cyan
    default: return .secondary
    }
  }
}

private struct TranscriptRow: View {
  let entry: TranscriptEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(entry.role == "user" ? "You" : "Jarvis")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(entry.role == "user" ? .cyan : .green)
      Text(entry.text)
        .font(.system(size: 13))
        .foregroundStyle(.white.opacity(0.82))
        .lineLimit(8)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(Color.white.opacity(0.035))
    )
  }
}

private struct VoiceWaveView: View {
  let phase: String
  let level: Double
  let connected: Bool
  let muted: Bool

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
      Canvas { context, size in
        let time = timeline.date.timeIntervalSinceReferenceDate
        // The runtime level already mixes mic RMS and assistant speech RMS, so
        // use it whenever connected — the assistant's voice must animate the
        // wave even while the microphone is muted.
        let liveLevel = connected ? min(max(level, 0), 1) : 0
        let phaseFloor: Double = {
          switch phase {
          case "speaking": return 0.08
          case "thinking", "acting": return 0.12
          case "connecting": return 0.10
          case "listening": return 0.06
          default: return 0.03
          }
        }()
        let energy = CGFloat(max(liveLevel, connected ? phaseFloor : 0.03))
        let centerY = size.height / 2
        let top = size.height * 0.18
        let bottom = size.height * 0.82
        let colors: [Color] = [
          Color(red: 0.23, green: 0.78, blue: 1.0),
          Color(red: 0.34, green: 1.0, blue: 0.74),
          Color(red: 1.0, green: 0.38, blue: 0.68),
          Color(red: 0.70, green: 0.42, blue: 1.0)
        ]

        let bed = Path(roundedRect: CGRect(x: 12, y: top, width: size.width - 24, height: bottom - top), cornerRadius: 18)
        context.fill(bed, with: .linearGradient(
          Gradient(colors: [
            colors[0].opacity(connected ? 0.10 + Double(energy) * 0.12 : 0.04),
            colors[2].opacity(connected ? 0.08 + Double(energy) * 0.10 : 0.03),
            colors[1].opacity(connected ? 0.10 + Double(energy) * 0.12 : 0.04)
          ]),
          startPoint: CGPoint(x: 12, y: centerY),
          endPoint: CGPoint(x: size.width - 12, y: centerY)
        ))

        let barCount = 44
        let barGap = size.width * 0.006
        let usableWidth = size.width - 38
        let barWidth = max(3, (usableWidth - CGFloat(barCount - 1) * barGap) / CGFloat(barCount))

        for index in 0..<barCount {
          let progress = Double(index) / Double(max(1, barCount - 1))
          let envelope = pow(sin(progress * Double.pi), 0.55)
          let carrier = 0.58 + 0.42 * sin(time * (phase == "speaking" ? 9.4 : 3.2) + progress * 13.0)
          let shimmer = 0.62 + 0.38 * sin(time * 5.6 + progress * 31.0)
          let normalizedHeight = CGFloat(envelope * carrier * shimmer) * (0.20 + energy * 0.78)
          let height = max(5, size.height * normalizedHeight * 0.62)
          let x = 19 + CGFloat(index) * (barWidth + barGap)
          let rect = CGRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
          let color = colors[index % colors.count].opacity(connected ? 0.28 + Double(energy) * 0.62 : 0.20)
          context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
        }

        for index in 0..<3 {
          var path = Path()
          let phaseOffset = Double(index) * 0.74
          let amplitude = size.height * (0.05 + energy * CGFloat(0.18 + Double(index) * 0.05))
          let frequency = 1.05 + Double(index) * 0.22
          let verticalOffset = CGFloat(index - 1) * (8 + energy * 10)

          for step in 0...220 {
            let x = size.width * CGFloat(step) / 220
            let progress = Double(step) / 220
            let envelope = pow(sin(progress * Double.pi), 0.72)
            let waveSpeed = (phase == "speaking" ? 4.7 : 1.7) + Double(index) * 0.38
            let waveAngle = progress * Double.pi * 2.0 * frequency + time * waveSpeed + phaseOffset
            let rippleAngle = progress * Double.pi * 8.0 + time * (phase == "speaking" ? 3.8 : 1.2) + phaseOffset
            let wave = sin(waveAngle)
            let ripple = sin(rippleAngle) * (0.16 + Double(energy) * 0.18)
            let combined = CGFloat(wave + ripple) * CGFloat(envelope)
            let y = centerY + verticalOffset + combined * amplitude

            if step == 0 {
              path.move(to: CGPoint(x: x, y: y))
            } else {
              path.addLine(to: CGPoint(x: x, y: y))
            }
          }

          context.stroke(
            path,
            with: .color(colors[index].opacity(connected ? 0.68 + Double(energy) * 0.25 : 0.28)),
            style: StrokeStyle(lineWidth: connected ? 3.0 + energy * 2.4 : 2.0, lineCap: .round, lineJoin: .round)
          )
        }
      }
    }
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.white.opacity(0.035))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    )
  }
}

private struct VoiceModeButton: View {
  enum Kind {
    case primary
    case neutral
    case danger
    case success
  }

  let title: String
  let icon: String
  var kind: Kind = .neutral
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 7) {
        Image(systemName: icon)
          .font(.system(size: 18, weight: .semibold))
        Text(title)
          .font(.system(size: 11, weight: .semibold))
      }
      .frame(width: 78, height: 68)
      .foregroundStyle(foreground)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(background)
      )
    }
    .buttonStyle(.plain)
  }

  private var foreground: Color {
    switch kind {
    case .primary: return .black
    case .neutral: return .white.opacity(0.84)
    case .danger: return Color(red: 1, green: 0.58, blue: 0.58)
    case .success: return Color(red: 0.55, green: 0.95, blue: 0.65)
    }
  }

  private var background: Color {
    switch kind {
    case .primary: return .white.opacity(0.92)
    case .neutral: return .white.opacity(0.08)
    case .danger: return .red.opacity(0.18)
    case .success: return .green.opacity(0.18)
    }
  }
}

private struct ExecutionModeButton: View {
  let title: String
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 11, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .foregroundStyle(selected ? .black : .white.opacity(0.82))
        .background(
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selected ? Color.white.opacity(0.9) : Color.white.opacity(0.07))
        )
    }
    .buttonStyle(.plain)
  }
}

private struct SystemRow: View {
  let label: String
  let value: String
  let ok: Bool

  var body: some View {
    HStack(spacing: 10) {
      Circle()
        .fill(ok ? Color.green : Color.red)
        .frame(width: 7, height: 7)
      Text(label)
        .font(.system(size: 13, weight: .medium))
      Spacer()
      Text(value.uppercased())
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .foregroundStyle(ok ? Color.green.opacity(0.75) : Color.red.opacity(0.85))
    }
    .padding(.vertical, 5)
  }
}

private struct SmallMetric: View {
  let label: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label.uppercased())
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundStyle(.white.opacity(0.76))
        .lineLimit(1)
    }
  }
}

private struct StatusPill: View {
  let label: String
  let color: Color

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)
      Text(label)
        .font(.system(size: 11, weight: .semibold))
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 6)
    .background(
      Capsule()
        .fill(Color.white.opacity(0.06))
    )
  }
}

private struct ControlButtonStyle: ButtonStyle {
  enum Kind {
    case primary
    case neutral
    case danger
    case success
  }

  var kind: Kind = .neutral

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .semibold))
      .padding(.horizontal, 11)
      .padding(.vertical, 7)
      .foregroundStyle(foreground)
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(background.opacity(configuration.isPressed ? 0.7 : 1))
      )
  }

  private var foreground: Color {
    switch kind {
    case .primary: return .black
    case .neutral: return .white.opacity(0.82)
    case .danger: return Color(red: 1, green: 0.58, blue: 0.58)
    case .success: return Color(red: 0.55, green: 0.95, blue: 0.65)
    }
  }

  private var background: Color {
    switch kind {
    case .primary: return .white.opacity(0.9)
    case .neutral: return .white.opacity(0.08)
    case .danger: return .red.opacity(0.18)
    case .success: return .green.opacity(0.18)
    }
  }
}

private func timeText(_ isoString: String) -> String {
  let formatter = ISO8601DateFormatter()
  guard let date = formatter.date(from: isoString) else {
    return ""
  }
  let display = DateFormatter()
  display.dateFormat = "HH:mm:ss"
  return display.string(from: date)
}
