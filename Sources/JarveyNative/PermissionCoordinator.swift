import Foundation

struct PermissionCoordinatorConfiguration: Sendable {
  var passiveRefreshInterval: TimeInterval
  var promptCooldown: TimeInterval
  var now: @Sendable () -> Date

  static let live = PermissionCoordinatorConfiguration(
    passiveRefreshInterval: 1.5,
    promptCooldown: 8,
    now: Date.init
  )
}

@MainActor
final class PermissionCoordinator {
  private let controller: PermissionControlling
  private let configuration: PermissionCoordinatorConfiguration

  private(set) var snapshot: NativePermissionSnapshot
  private var lastPassiveRefreshAt: Date?
  private var lastScreenRequestAt: Date?
  private var lastAccessibilityRequestAt: Date?

  init(
    controller: PermissionControlling = PermissionsController(),
    configuration: PermissionCoordinatorConfiguration = .live
  ) {
    self.controller = controller
    self.configuration = configuration
    self.snapshot = controller.passiveSnapshot()
    self.lastPassiveRefreshAt = configuration.now()
  }

  func currentSnapshot() -> NativePermissionSnapshot {
    snapshot
  }

  @discardableResult
  func refresh(force: Bool = false) -> NativePermissionSnapshot {
    if !force,
       let lastPassiveRefreshAt,
       configuration.now().timeIntervalSince(lastPassiveRefreshAt) < configuration.passiveRefreshInterval {
      return snapshot
    }

    snapshot = controller.passiveSnapshot()
    lastPassiveRefreshAt = configuration.now()
    return snapshot
  }

  @discardableResult
  func requestMicrophone() async -> NativePermissionSnapshot {
    await controller.requestMicrophoneAccess()
    return refresh(force: true)
  }

  @discardableResult
  func requestScreenRecording() async -> NativePermissionSnapshot {
    let nextSnapshot = refresh(force: true)
    guard nextSnapshot.screen != "granted" else {
      return nextSnapshot
    }

    if isOnCooldown(lastScreenRequestAt) {
      return nextSnapshot
    }

    lastScreenRequestAt = configuration.now()
    await controller.requestScreenRecordingAccess()
    let refreshedSnapshot = refresh(force: true)
    guard refreshedSnapshot.screen != "granted" else {
      return refreshedSnapshot
    }
    controller.openScreenRecordingSettings()
    return refresh(force: true)
  }

  @discardableResult
  func requestAccessibility() -> NativePermissionSnapshot {
    let nextSnapshot = refresh(force: true)
    guard !nextSnapshot.accessibilityTrusted else {
      return nextSnapshot
    }

    if isOnCooldown(lastAccessibilityRequestAt) {
      return nextSnapshot
    }

    lastAccessibilityRequestAt = configuration.now()
    controller.requestAccessibilityPrompt()
    return refresh(force: true)
  }

  private func isOnCooldown(_ timestamp: Date?) -> Bool {
    guard let timestamp else {
      return false
    }
    return configuration.now().timeIntervalSince(timestamp) < configuration.promptCooldown
  }
}
