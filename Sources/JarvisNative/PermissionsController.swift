import AVFoundation
import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

@MainActor
protocol PermissionControlling: AnyObject {
  func passiveSnapshot() -> NativePermissionSnapshot
  func requestMicrophoneAccess() async
  func requestScreenRecordingAccess() async
  func openScreenRecordingSettings()
  func requestAccessibilityPrompt()
}

@MainActor
final class PermissionsController: PermissionControlling {
  func passiveSnapshot() -> NativePermissionSnapshot {
    NativePermissionSnapshot(
      microphone: microphoneStatusString(),
      screen: checkScreenRecordingGranted() ? "granted" : "not-determined",
      accessibilityTrusted: checkAccessibilityTrusted(),
      voiceRuntimeSupported: hasMicrophoneUsageDescription()
    )
  }

  func requestMicrophoneAccess() async {
    _ = await AVCaptureDevice.requestAccess(for: .audio)
  }

  func requestScreenRecordingAccess() async {
    // Only explicit user-triggered permission repair flows should call the
    // prompting API. Passive checks must remain non-prompting.
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        _ = CGRequestScreenCaptureAccess()
        continuation.resume()
      }
    }
  }

  func openScreenRecordingSettings() {
    // Open System Settings directly at the Screen Recording pane after the
    // explicit request path has registered the app with TCC.
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
      NSWorkspace.shared.open(url)
    }
  }

  func requestAccessibilityPrompt() {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }

  private func microphoneStatusString() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return "granted"
    case .denied:
      return "denied"
    case .restricted:
      return "restricted"
    case .notDetermined:
      return "not-determined"
    @unknown default:
      return "unknown"
    }
  }

  /// Check screen recording permission without triggering a prompt.
  /// CGPreflightScreenCaptureAccess is the documented non-prompting API.
  /// Avoid window-list heuristics here because false positives allow the
  /// sidecar to invoke screencapture, which then triggers the system dialog.
  private func checkScreenRecordingGranted() -> Bool {
    CGPreflightScreenCaptureAccess()
  }

  /// Check accessibility trust.  Only AXIsProcessTrusted() gives a reliable
  /// answer for CGEvent posting — the AXUIElement fallback can return true
  /// even when event posting is silently blocked.
  private func checkAccessibilityTrusted() -> Bool {
    AXIsProcessTrusted()
  }

  private func hasMicrophoneUsageDescription() -> Bool {
    guard let value = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String else {
      return false
    }
    return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
