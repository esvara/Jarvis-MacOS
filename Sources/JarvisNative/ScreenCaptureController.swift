import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

enum ScreenCaptureError: LocalizedError {
  case captureUnavailable
  case bitmapContextUnavailable
  case encodeFailed

  var errorDescription: String? {
    switch self {
    case .captureUnavailable:
      return "Screen capture failed. Grant Screen Recording access to Jarvis and try again."
    case .bitmapContextUnavailable:
      return "Screen capture bitmap context could not be created."
    case .encodeFailed:
      return "Screen capture PNG encoding failed."
    }
  }
}

final class ScreenCaptureController {
  func captureBase64PNG() async throws -> String {
    let image = try await captureMainDisplayImage()
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(
      using: .jpeg,
      properties: [.compressionFactor: 0.75]
    ) else {
      throw ScreenCaptureError.encodeFailed
    }
    return data.base64EncodedString()
  }

  private func captureMainDisplayImage() async throws -> CGImage {
    let shareableContent = try await currentShareableContent()
    let targetDisplayID = CGMainDisplayID()
    guard let display = shareableContent.displays.first(where: { $0.displayID == targetDisplayID })
        ?? shareableContent.displays.first else {
      throw ScreenCaptureError.captureUnavailable
    }

    // SCDisplay.width/height are already in logical points (not retina pixels),
    // so capture at that size to match the coordinate space the model uses.
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let configuration = SCStreamConfiguration()
    configuration.width = max(display.width, 1)
    configuration.height = max(display.height, 1)
    configuration.minimumFrameInterval = .zero

    return try await captureImage(filter: filter, configuration: configuration)
  }

  private func currentShareableContent() async throws -> SCShareableContent {
    try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
  }

  private func captureImage(
    filter: SCContentFilter,
    configuration: SCStreamConfiguration
  ) async throws -> CGImage {
    try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
  }
}
