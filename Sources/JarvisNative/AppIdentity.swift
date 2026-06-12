import Foundation

enum AppIdentity {
  static let appName = "Jarvis"
  static let voiceMessageHandlerName = "jarvisVoice"
  static let voiceBridgeObjectName = "jarvisVoiceBridge"

  static func applicationSupportRoot(fileManager: FileManager = .default) -> URL {
    let baseDirectory =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: "Library", directoryHint: .isDirectory)
        .appending(path: "Application Support", directoryHint: .isDirectory)
    return baseDirectory.appending(path: appName, directoryHint: .isDirectory)
  }

  static let resourceBundle: Bundle = {
    // Prefer SPM's generated resource bundle when available (swift build / debug),
    // fall back to the main app bundle (packaged .app).
    if let spmBundle = Bundle(url: Bundle.main.bundleURL
          .appending(path: "JarvisNative_JarvisNative.bundle")) {
      return spmBundle
    }
    return Bundle.main
  }()

  static func logsDirectory(fileManager: FileManager = .default) -> URL {
    let logsDirectory = applicationSupportRoot(fileManager: fileManager)
      .appending(path: "logs", directoryHint: .isDirectory)
    try? fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    return logsDirectory
  }
}
