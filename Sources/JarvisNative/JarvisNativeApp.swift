import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let permissionCoordinator = PermissionCoordinator()
  private let localAuthToken = LocalAuthToken.generate()
  private lazy var model = AppModel(
    permissionCoordinator: permissionCoordinator,
    localAuthToken: localAuthToken
  )
  private var panelController: OverlayPanelController?
  private var voiceHostWindow: NSWindow?
  private var hotKeyController: GlobalHotKeyController?
  private var voiceController: VoiceBridgeController?
  private var inputServer: InputActionServer?
  private var statusBarController: StatusBarController?
  private var onboardingController: OnboardingWindowController?
  private var controlWindowController: ControlWindowController?
  private var cancellables = Set<AnyCancellable>()
  private var hotkeyListeningActive = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      let server = try InputActionServer(
        permissionCoordinator: permissionCoordinator,
        authToken: localAuthToken
      )
      server.onListenerFailed = { [weak self] message in
        Task { @MainActor in
          self?.model.errorMessage = message
        }
      }
      server.start()
      inputServer = server
    } catch {
      print("Failed to start input action server: \(error)")
    }

    NSApp.setActivationPolicy(.accessory)

    // Status bar icon (permanent, holds settings)
    let controlWindowController = ControlWindowController(model: model)
    self.controlWindowController = controlWindowController
    statusBarController = StatusBarController(model: model) { [weak controlWindowController] in
      controlWindowController?.show()
    }

    // Overlay bar (starts hidden)
    let panelController = OverlayPanelController(
      model: model,
      onDismissRequested: { [weak self] in
        self?.hideOverlay()
      },
      onListenRequested: { [weak self] in
        Task {
          await self?.model.startListening()
        }
      }
    )
    self.panelController = panelController

    hotKeyController = GlobalHotKeyController(
      onPress: { [weak self] in
        DispatchQueue.main.async {
          self?.handleHotkeyPress()
        }
      },
      onRelease: { [weak self] in
        DispatchQueue.main.async {
          self?.handleHotkeyRelease()
        }
      }
    )

    bindOverlayLifecycle()
    bindHotkeyUpdates()

    Task {
      await model.bootstrap()
      // Apply saved hotkey from settings
      if !model.settings.hotkey.isEmpty {
        hotKeyController?.updateHotkey(model.settings.hotkey)
      }

      if let hostView = makeVoiceHostWindow().contentView {
        let voiceController = VoiceBridgeController(
          hostView: hostView,
          authToken: self.localAuthToken
        ) { [weak model] event in
          model?.handleVoiceEvent(event)
        }
        self.voiceController = voiceController
        model.attachVoiceController(voiceController)
      }

      // Show onboarding on first launch, or settings popover for returning users with issues
      if !OnboardingWindowController.hasCompletedOnboarding {
        let onboarding = OnboardingWindowController()
        onboarding.onFinished = { [weak self] in
          self?.onboardingController = nil
        }
        onboarding.show(model: model)
        self.onboardingController = onboarding
      } else if model.hasBlockingSetupIssue {
        statusBarController?.showPopover()
      }
    }
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    model.applicationDidBecomeActive()
  }

  func applicationWillTerminate(_ notification: Notification) {
    inputServer?.stop()
    model.shutdown()
  }

  private func bindOverlayLifecycle() {
    model.$activeTaskId
      .combineLatest(model.$pendingApproval, model.$pendingRealtimeApproval)
      .sink { [weak self] activeTaskId, pendingApproval, pendingRealtimeApproval in
        let canDismissOnClickAway = activeTaskId == nil && pendingApproval == nil && pendingRealtimeApproval == nil
        self?.panelController?.setClickAwayDismissEnabled(canDismissOnClickAway)
      }
      .store(in: &cancellables)
  }

  private func makeVoiceHostWindow() -> NSWindow {
    if let voiceHostWindow {
      return voiceHostWindow
    }

    let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
    let window = NSWindow(
      contentRect: NSRect(x: screenFrame.minX + 8, y: screenFrame.minY + 8, width: 4, height: 4),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.backgroundColor = .clear
    window.isOpaque = false
    window.alphaValue = 0.05
    window.ignoresMouseEvents = true
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 4, height: 4))
    window.orderFrontRegardless()
    voiceHostWindow = window
    return window
  }

  private func bindHotkeyUpdates() {
    model.$settings
      .map(\.hotkey)
      .removeDuplicates()
      .sink { [weak self] hotkey in
        guard !hotkey.isEmpty else { return }
        self?.hotKeyController?.updateHotkey(hotkey)
      }
      .store(in: &cancellables)
  }

  private func handleHotkeyPress() {
    showOverlay()
    guard !hotkeyListeningActive else {
      return
    }
    hotkeyListeningActive = true
    Task {
      await model.startListening()
    }
  }

  private func handleHotkeyRelease() {
    hotkeyListeningActive = false
    guard model.usesPushToTalk else {
      return
    }
    Task {
      await model.stopListening()
    }
  }

  private func showOverlay() {
    guard let panelController else { return }
    model.refreshPermissions(force: true)
    if !panelController.isVisible {
      panelController.show()
    }
  }

  private func hideOverlay() {
    guard let panelController, panelController.isVisible else { return }
    panelController.hide()
    Task { await model.overlayDeactivated() }
  }
}

@main
struct JarvisNativeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    Settings {
      EmptyView()
    }
  }
}
