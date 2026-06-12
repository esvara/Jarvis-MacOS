import AppKit
import SwiftUI

final class OverlayPanelController: NSWindowController {
  private enum Metrics {
    static let panelWidth: CGFloat = 560
    static let panelHeight: CGFloat = 214
    static let edgeInset: CGFloat = 24
  }

  private let onDismissRequested: () -> Void
  private let onListenRequested: () -> Void
  private var clickAwayDismissEnabled = true

  init(
    model: AppModel,
    onDismissRequested: @escaping () -> Void,
    onListenRequested: @escaping () -> Void
  ) {
    self.onDismissRequested = onDismissRequested
    self.onListenRequested = onListenRequested
    let panel = OverlayPanel(
      contentRect: NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: Metrics.panelHeight),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
    panel.hidesOnDeactivate = false
    panel.sharingType = .none
    panel.isMovableByWindowBackground = false
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.standardWindowButton(.closeButton)?.isHidden = true
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    panel.standardWindowButton(.zoomButton)?.isHidden = true

    let hostingView = OverlayHostingView(
      rootView: OverlayBarView(
        model: model,
        onDismissRequested: onDismissRequested,
        onListenRequested: onListenRequested
      )
    )
    hostingView.translatesAutoresizingMaskIntoConstraints = false

    let container = OverlayContainerView()
    container.addSubview(hostingView)
    NSLayoutConstraint.activate([
      hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      hostingView.topAnchor.constraint(equalTo: container.topAnchor),
      hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
    ])

    panel.contentView = container

    super.init(window: panel)
    panel.delegate = self
    positionWindow()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func toggle() {
    guard let window else { return }
    if window.isVisible { hide() } else { show() }
  }

  // M: Animated show with fade + slide from top-right
  func show() {
    positionWindow()
    guard let window else { return }
    let target = window.frame.origin
    window.alphaValue = 0
    window.setFrameOrigin(NSPoint(x: target.x + 8, y: target.y + 8))
    window.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.25
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      window.animator().alphaValue = 1
      window.animator().setFrameOrigin(target)
    }
  }

  // M: Animated hide with fade + slide to top-right
  func hide() {
    guard let window else { return }
    let origin = window.frame.origin
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.2
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      window.animator().alphaValue = 0
      window.animator().setFrameOrigin(NSPoint(x: origin.x + 8, y: origin.y + 8))
    }, completionHandler: { [weak window] in
      window?.orderOut(nil)
      window?.alphaValue = 1
    })
  }

  var isVisible: Bool {
    window?.isVisible ?? false
  }

  func setClickAwayDismissEnabled(_ enabled: Bool) {
    clickAwayDismissEnabled = enabled
  }

  private func positionWindow() {
    guard let window, let screen = NSScreen.main else { return }
    let frame = screen.visibleFrame
    let x = frame.maxX - Metrics.panelWidth - Metrics.edgeInset
    let y = frame.maxY - Metrics.panelHeight - Metrics.edgeInset
    window.setFrameOrigin(NSPoint(x: x, y: y))
  }
}

// MARK: - Panel

private final class OverlayPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

private final class OverlayContainerView: NSView {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class OverlayHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Bar View

private struct OverlayBarView: View {
  @ObservedObject var model: AppModel
  let onDismissRequested: () -> Void
  let onListenRequested: () -> Void

  private var actionCallout: OverlayActionCallout? {
    model.overlayActionCallout
  }

  // C: Distinguish state labels from transcript text
  private var isStateLabel: Bool {
    ["Listening.", "Thinking.", "Speaking."].contains(compactText)
  }

  // E: Dynamic bar width — compact for short state labels, full for content
  private var barWidth: CGFloat {
    let hasApproval = model.pendingApproval != nil || model.pendingRealtimeApproval != nil
    if hasApproval || actionCallout != nil { return 560 }
    if isStateLabel { return 320 }
    return 560
  }

  var body: some View {
    VStack(alignment: .trailing, spacing: actionCallout == nil ? 0 : -10) {
      compactBar
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
        .zIndex(2)

      if let actionCallout {
        actionCalloutBar(actionCallout)
          .transition(.opacity.combined(with: .move(edge: .top)))
          .zIndex(1)
      }
    }
    .environment(\.colorScheme, .dark)
    .animation(.spring(response: 0.32, dampingFraction: 0.84), value: actionCallout)
    .animation(.spring(response: 0.4, dampingFraction: 0.82), value: barWidth)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 18)
        .onEnded { value in
          let draggedFarEnough =
            value.translation.width > 120 || abs(value.translation.height) > 90
          if draggedFarEnough {
            onDismissRequested()
          }
        }
    )
  }

  // MARK: - Compact Bar

  private var compactBar: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 14) {
        DotGridCanvas(
          cols: 3, rows: 3,
          level: model.voiceState.level,
          phase: displayPhase,
          connected: displayConnected,
          muted: displayMuted
        )
        .frame(width: 48, height: 48)

        // C: State labels get medium weight at 17pt, transcript text gets regular at 15pt
        Text(compactText)
          .font(.system(size: isStateLabel ? 17 : 15, weight: isStateLabel ? .medium : .regular))
          .foregroundStyle(compactTextColor)
          .lineLimit(2)

        Spacer(minLength: 0)

        Button {
          onDismissRequested()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color.white.opacity(0.58))
            .frame(width: 28, height: 28)
            .background(
              Circle()
                .fill(Color.white.opacity(0.08))
                .overlay(
                  Circle().stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
            )
        }
        .buttonStyle(.plain)
        .help("Close Jarvis")
      }

      // D: Approval section with divider and improved buttons
      if model.pendingApproval != nil || model.pendingRealtimeApproval != nil {
        Rectangle()
          .fill(Color.white.opacity(0.06))
          .frame(height: 1)
          .padding(.top, 10)
          .padding(.horizontal, 4)

        HStack(spacing: 8) {
          BarPillButton(title: "Approve", emphasized: true) {
            Task {
              if model.pendingRealtimeApproval != nil {
                await model.approveRealtimeApproval()
              } else {
                await model.approvePending()
              }
            }
          }
          BarPillButton(title: "Reject", emphasized: false) {
            Task {
              if model.pendingRealtimeApproval != nil {
                await model.rejectRealtimeApproval()
              } else {
                await model.rejectPending()
              }
            }
          }
          Spacer()
        }
        .padding(.top, 8)
        .padding(.leading, 62)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(width: barWidth)
    .background(barBackground)
    .onTapGesture {
      guard model.pendingApproval == nil, model.pendingRealtimeApproval == nil else {
        return
      }
      onListenRequested()
    }
  }

  // MARK: - Helpers

  // A + B: Vibrancy material background with subtle border and softer shadow
  private var barBackground: some View {
    RoundedRectangle(cornerRadius: 22, style: .continuous)
      .fill(.ultraThinMaterial)
      .overlay(
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .fill(Color(white: 0.04).opacity(0.7))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .stroke(Color.white.opacity(0.06), lineWidth: 1)
      )
      .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
      .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
  }

  // J + K + L: Dark-themed callout with connected shape and pill label
  private func actionCalloutBar(_ callout: OverlayActionCallout) -> some View {
    HStack(spacing: 0) {
      Spacer(minLength: 132)

      HStack(spacing: 10) {
        Text(callout.label.uppercased())
          .font(.system(size: 10, weight: .bold, design: .rounded))
          .tracking(0.5)
          .foregroundStyle(Color.white.opacity(0.45))
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(
            Capsule(style: .continuous).fill(Color.white.opacity(0.08))
          )

        Text(callout.text)
          .font(.system(size: 15, weight: .regular))
          .foregroundStyle(Color.white.opacity(0.5))
          .lineLimit(1)
          .truncationMode(.tail)

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 20)
      .frame(width: 396, height: 46, alignment: .leading)
      .background(
        UnevenRoundedRectangle(
          topLeadingRadius: 6,
          bottomLeadingRadius: 16,
          bottomTrailingRadius: 16,
          topTrailingRadius: 6,
          style: .continuous
        )
        .fill(Color(white: 0.08).opacity(0.95))
        .overlay(
          UnevenRoundedRectangle(
            topLeadingRadius: 6,
            bottomLeadingRadius: 16,
            bottomTrailingRadius: 16,
            topTrailingRadius: 6,
            style: .continuous
          )
          .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
      )
    }
    .padding(.trailing, 12)
  }

  private var compactTextColor: Color {
    switch displayPhase {
    case "speaking":
      return Color.white.opacity(0.72)
    case "thinking", "listening", "acting":
      return Color.white.opacity(0.62)
    case "error":
      return Color(red: 1, green: 0.48, blue: 0.48)
    default:
      return Color.white.opacity(0.45)
    }
  }

  private var latestTranscript: TranscriptEntry? {
    model.transcript.last(where: { !$0.text.isEmpty })
  }

  private var displayConnected: Bool {
    model.listeningModeActive || model.voiceState.connected
  }

  private var displayMuted: Bool {
    if !model.voiceState.connected {
      return !model.listeningModeActive
    }
    return model.voiceState.muted
  }

  private var displayPhase: String {
    if model.listeningModeActive && !model.voiceState.connected {
      return "listening"
    }

    switch model.phase {
    case "error", "approvals", "listening":
      return model.phase
    case "connecting":
      return model.listeningModeActive ? "listening" : "connecting"
    case "acting", "thinking", "speaking":
      if let latestTranscript, latestTranscript.role == "assistant" {
        return "speaking"
      }
      if model.phase == "speaking" {
        return "speaking"
      }
      return "thinking"
    default:
      return model.phase
    }
  }

  private var compactText: String {
    if let approval = model.pendingRealtimeApproval {
      return approval.title
    }
    if let approval = model.pendingApproval {
      return approval.summary
    }
    if model.phase == "error", !model.displayErrorMessage.isEmpty {
      return model.displayErrorMessage
    }
    if displayPhase == "listening" {
      return "Listening."
    }
    if displayPhase == "thinking" {
      if let entry = latestTranscript, entry.role == "user" || entry.role == "assistant" {
        return entry.text
      }
      return "Thinking."
    }
    if displayPhase == "speaking" {
      if let entry = latestTranscript {
        return entry.text
      }
      return "Speaking."
    }
    if let entry = latestTranscript {
      let role = entry.role == "user" ? "User" : "Jarvis"
      return "[\(role)] \(entry.text)"
    }
    return model.compactStatus
  }
}

extension OverlayPanelController: NSWindowDelegate {
  func windowDidResignKey(_ notification: Notification) {
    guard clickAwayDismissEnabled, isVisible else {
      return
    }
    onDismissRequested()
  }
}

// MARK: - Dot Grid Canvas

private struct DotGridCanvas: View {
  private enum ActivePattern {
    case centerDot
    case outerFrame
    case middleColumn
    case outerColumns
    case middleRow
    case outerRows
    case none
    case all
  }

  let cols: Int
  let rows: Int
  let level: Double
  let phase: String
  let connected: Bool
  let muted: Bool

  // H: Track previous phase for smooth cross-fade transitions
  @State private var previousPhase: String = ""
  @State private var phaseChangeTime: Double = 0

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: false)) { timeline in
      Canvas { context, size in
        drawGrid(context: context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
      }
    }
    .onChange(of: phase) { oldValue, newValue in
      previousPhase = oldValue
      phaseChangeTime = Date().timeIntervalSinceReferenceDate
    }
  }

  private var isCompact: Bool { cols <= 3 }

  private func drawGrid(context: GraphicsContext, size: CGSize, time: Double) {
    let gap: CGFloat = isCompact ? 4 : 5
    let dotW = (size.width - CGFloat(cols - 1) * gap) / CGFloat(cols)
    let dotH = (size.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
    let baseDotSize = min(dotW, dotH)
    let totalW = CGFloat(cols) * baseDotSize + CGFloat(cols - 1) * gap
    let totalH = CGFloat(rows) * baseDotSize + CGFloat(rows - 1) * gap
    let ox = (size.width - totalW) / 2
    let oy = (size.height - totalH) / 2

    // H: Compute blend factor for cross-fading between phase patterns
    let transitionDuration = 0.2
    let timeSinceChange = time - phaseChangeTime
    let blend = phaseChangeTime > 0 ? min(timeSinceChange / transitionDuration, 1.0) : 1.0

    let currentCycle = animationCycle(time: time, forPhase: phase)

    for row in 0..<rows {
      for col in 0..<cols {
        // H: Cross-fade dot brightness between old and new phase
        let currentWhite = dotWhite(row: row, col: col, time: time, forPhase: phase)
        let prevWhite = blend < 1.0
          ? dotWhite(row: row, col: col, time: time, forPhase: previousPhase)
          : currentWhite
        let white = prevWhite + (currentWhite - prevWhite) * blend

        let isActive = isCellActive(row: row, col: col, pattern: currentCycle.pattern)

        // G: Level-reactive dot sizing — active dots grow with audio level
        let levelScale = isActive && !muted && connected ? (1.0 + level * 0.14) : 1.0
        let dotSize = baseDotSize * levelScale
        let offsetAdj = (baseDotSize - dotSize) / 2

        let x = ox + CGFloat(col) * (baseDotSize + gap) + offsetAdj
        let y = oy + CGFloat(row) * (baseDotSize + gap) + offsetAdj
        let rect = CGRect(x: x, y: y, width: dotSize, height: dotSize)

        // F: Circular dots instead of rounded squares
        let path = Path(ellipseIn: rect)

        // I: Subtle glow behind active dots during speaking/listening
        if isActive && !muted && connected && (phase == "speaking" || phase == "listening") {
          let glowInset = -dotSize * 0.25
          let glowRect = rect.insetBy(dx: glowInset, dy: glowInset)
          let glowPath = Path(ellipseIn: glowRect)
          context.fill(glowPath, with: .color(Color.white.opacity(white * 0.12)))
        }

        if phase == "error" {
          context.fill(path, with: .color(Color(red: white * 2.5, green: white * 0.8, blue: white * 0.8)))
        } else if phase == "approvals" {
          context.fill(path, with: .color(Color(red: white * 2.2, green: white * 1.8, blue: white * 0.8)))
        } else {
          context.fill(path, with: .color(Color(white: white)))
        }
      }
    }
  }

  private func dotWhite(row: Int, col: Int, time: Double, forPhase: String) -> Double {
    let cycle = animationCycle(time: time, forPhase: forPhase)
    let isActive = isCellActive(row: row, col: col, pattern: cycle.pattern)
    let activeWhite = 0.88 + cycle.emphasis * 0.08
    let inactiveWhite = 0.22 + cycle.emphasis * 0.04

    // N: More visible idle breathing animation (0.15–0.22 range)
    if muted || !connected {
      let idle = (sin(time * 0.9) + 1) / 2
      return 0.15 + idle * 0.07
    }

    switch forPhase {
    case "approvals":
      return isActive ? 0.78 : 0.28
    case "error":
      return isActive ? 0.44 : 0.18
    default:
      return isActive ? activeWhite : inactiveWhite
    }
  }

  private func animationCycle(time: Double, forPhase: String) -> (pattern: ActivePattern, emphasis: Double) {
    let beat = Int(floor(time / 0.42)).quotientAndRemainder(dividingBy: 2).remainder
    let emphasis = (sin(time * 5.4) + 1) / 2

    switch forPhase {
    case "speaking":
      return (
        beat == 0 ? .centerDot : .outerFrame,
        emphasis
      )
    case "thinking", "acting", "connecting":
      return (
        beat == 0 ? .middleColumn : .outerColumns,
        emphasis
      )
    case "listening":
      return (
        beat == 0 ? .middleRow : .outerRows,
        emphasis
      )
    case "approvals":
      return (.all, emphasis)
    case "error":
      return (.centerDot, emphasis)
    default:
      return (.none, emphasis)
    }
  }

  private func isCellActive(row: Int, col: Int, pattern: ActivePattern) -> Bool {
    let centerRow = rows / 2
    let centerCol = cols / 2

    switch pattern {
    case .centerDot:
      return row == centerRow && col == centerCol
    case .outerFrame:
      return !(row == centerRow && col == centerCol)
    case .middleColumn:
      return col == centerCol
    case .outerColumns:
      return col != centerCol
    case .middleRow:
      return row == centerRow
    case .outerRows:
      return row != centerRow
    case .all:
      return true
    case .none:
      return false
    }
  }
}

// MARK: - Bar Pill Button

// D: Larger touch targets, better visibility, press animation
private struct BarPillButton: View {
  let title: String
  var emphasized: Bool = true
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .foregroundStyle(emphasized ? Color.black : Color.white.opacity(0.7))
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(
          Capsule(style: .continuous)
            .fill(
              emphasized
                ? Color.white.opacity(isHovered ? 1 : 0.85)
                : Color.white.opacity(isHovered ? 0.20 : 0.12)
            )
        )
    }
    .buttonStyle(ScalePressButtonStyle())
    .onHover { isHovered = $0 }
  }
}

private struct ScalePressButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
      .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
  }
}
