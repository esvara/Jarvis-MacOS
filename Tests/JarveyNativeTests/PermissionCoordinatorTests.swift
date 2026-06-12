@testable import JarveyNative
import XCTest

@MainActor
final class PermissionCoordinatorTests: XCTestCase {
  func testRefreshUsesCachedSnapshotWithinPassiveInterval() {
    let controller = MockPermissionController()
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
    let coordinator = PermissionCoordinator(
      controller: controller,
      configuration: PermissionCoordinatorConfiguration(
        passiveRefreshInterval: 5,
        promptCooldown: 8,
        now: { clock.now }
      )
    )

    XCTAssertEqual(controller.passiveSnapshotCallCount, 1)
    XCTAssertEqual(coordinator.refresh().screen, "not-determined")
    XCTAssertEqual(controller.passiveSnapshotCallCount, 1)

    clock.now.addTimeInterval(6)
    XCTAssertEqual(coordinator.refresh().screen, "not-determined")
    XCTAssertEqual(controller.passiveSnapshotCallCount, 2)
  }

  func testScreenRequestOpensSettingsOnlyOncePerCooldownWindow() async {
    let controller = MockPermissionController()
    let clock = TestClock(now: Date(timeIntervalSince1970: 2_000))
    let coordinator = PermissionCoordinator(
      controller: controller,
      configuration: PermissionCoordinatorConfiguration(
        passiveRefreshInterval: 0,
        promptCooldown: 10,
        now: { clock.now }
      )
    )

    _ = await coordinator.requestScreenRecording()
    _ = await coordinator.requestScreenRecording()
    XCTAssertEqual(controller.screenRequestCount, 1)
    XCTAssertEqual(controller.screenSettingsOpenCount, 1)

    clock.now.addTimeInterval(11)
    _ = await coordinator.requestScreenRecording()
    XCTAssertEqual(controller.screenRequestCount, 2)
    XCTAssertEqual(controller.screenSettingsOpenCount, 2)
  }

  func testAccessibilityRequestIsSkippedWhenAlreadyGranted() {
    let controller = MockPermissionController()
    controller.snapshot = NativePermissionSnapshot(
      microphone: "granted",
      screen: "granted",
      accessibilityTrusted: true,
      voiceRuntimeSupported: true
    )

    let coordinator = PermissionCoordinator(
      controller: controller,
      configuration: PermissionCoordinatorConfiguration(
        passiveRefreshInterval: 0,
        promptCooldown: 10,
        now: Date.init
      )
    )

    _ = coordinator.requestAccessibility()
    XCTAssertEqual(controller.accessibilityPromptCount, 0)
  }

  func testScreenGrantIsNotStickyAcrossRefreshes() {
    let controller = MockPermissionController()
    controller.snapshot = NativePermissionSnapshot(
      microphone: "granted",
      screen: "granted",
      accessibilityTrusted: true,
      voiceRuntimeSupported: true
    )
    let clock = TestClock(now: Date(timeIntervalSince1970: 3_000))
    let coordinator = PermissionCoordinator(
      controller: controller,
      configuration: PermissionCoordinatorConfiguration(
        passiveRefreshInterval: 0,
        promptCooldown: 10,
        now: { clock.now }
      )
    )

    XCTAssertEqual(coordinator.currentSnapshot().screen, "granted")

    controller.snapshot.screen = "not-determined"
    XCTAssertEqual(coordinator.refresh(force: true).screen, "not-determined")
  }

  func testScreenSettingsAreSkippedWhenPromptGrantsAccess() async {
    let controller = MockPermissionController()
    controller.onScreenRequest = {
      controller.snapshot.screen = "granted"
    }

    let coordinator = PermissionCoordinator(
      controller: controller,
      configuration: PermissionCoordinatorConfiguration(
        passiveRefreshInterval: 0,
        promptCooldown: 10,
        now: Date.init
      )
    )

    let snapshot = await coordinator.requestScreenRecording()
    XCTAssertEqual(snapshot.screen, "granted")
    XCTAssertEqual(controller.screenRequestCount, 1)
    XCTAssertEqual(controller.screenSettingsOpenCount, 0)
  }
}

@MainActor
private final class MockPermissionController: PermissionControlling {
  var snapshot = NativePermissionSnapshot(
    microphone: "granted",
    screen: "not-determined",
    accessibilityTrusted: false,
    voiceRuntimeSupported: true
  )

  var passiveSnapshotCallCount = 0
  var screenRequestCount = 0
  var screenSettingsOpenCount = 0
  var accessibilityPromptCount = 0
  var onScreenRequest: (() -> Void)?

  func passiveSnapshot() -> NativePermissionSnapshot {
    passiveSnapshotCallCount += 1
    return snapshot
  }

  func requestMicrophoneAccess() async {}

  func requestScreenRecordingAccess() async {
    screenRequestCount += 1
    onScreenRequest?()
  }

  func openScreenRecordingSettings() {
    screenSettingsOpenCount += 1
  }

  func requestAccessibilityPrompt() {
    accessibilityPromptCount += 1
  }
}

private final class TestClock: @unchecked Sendable {
  var now: Date

  init(now: Date) {
    self.now = now
  }
}
