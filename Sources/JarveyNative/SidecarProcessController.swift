import Foundation
@MainActor
final class SidecarProcessController {
  private var process: Process?
  private let port = LocalEndpoints.sidecarPort
  private let authToken: String

  init(authToken: String = "") {
    self.authToken = authToken
  }

  func ensureRunning(using client: SidecarClient) async throws {
    if let health = try? await client.health(), health.secured == true {
      // The listening sidecar must accept this session's token; otherwise it
      // is an orphan from a previous session — terminate it (its pid comes
      // from /health) and start a fresh one.
      if (try? await client.settings()) != nil {
        return
      }
      if health.pid > 0 {
        kill(pid_t(health.pid), SIGTERM)
        for _ in 0 ..< 20 {
          if (try? await client.health()) == nil {
            break
          }
          try await Task.sleep(for: .milliseconds(250))
        }
      }
      if (try? await client.health()) != nil {
        throw SidecarStartupError.staleUnauthorizedSidecar
      }
    }

    let runtimeRoot = resolvedRuntimeRoot()
    let scriptURL = runtimeRoot.appending(path: "dist-sidecar", directoryHint: .isDirectory)
      .appending(path: "sidecar.cjs")
    guard FileManager.default.fileExists(atPath: scriptURL.path) else {
      throw SidecarStartupError.missingSidecarBinary(scriptURL.path)
    }

    let workingDirectory = hostWorkingDirectory()
    let process = Process()
    process.currentDirectoryURL = workingDirectory
    var environment = ProcessInfo.processInfo.environment
    if !authToken.isEmpty {
      environment["JARVEY_AUTH_TOKEN"] = authToken
    }
    process.environment = environment
    process.standardOutput = Pipe()
    process.standardError = Pipe()

    if let bundledNode = bundledNodeExecutableURL() {
      process.executableURL = bundledNode
      process.arguments = [
        scriptURL.path,
        "--port", "\(port)",
        "--assets-root", runtimeRoot.path,
        "--working-directory", workingDirectory.path
      ]
    } else {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [
        "node",
        scriptURL.path,
        "--port", "\(port)",
        "--assets-root", runtimeRoot.path,
        "--working-directory", workingDirectory.path
      ]
    }

    try process.run()
    self.process = process

    for _ in 0 ..< 40 {
      if (try? await client.health()) != nil {
        return
      }
      try await Task.sleep(for: .milliseconds(250))
    }

    throw SidecarStartupError.failedToBecomeHealthy
  }

  /// Terminate the sidecar this app instance spawned (no-op otherwise).
  func terminate() {
    process?.terminate()
    process = nil
  }

  private func resolvedRuntimeRoot() -> URL {
    if let bundledRoot = bundledRuntimeRoot() {
      return bundledRoot
    }
    return developmentProjectRoot()
  }

  private func bundledRuntimeRoot() -> URL? {
    guard let resourceURL = Bundle.main.resourceURL else {
      return nil
    }

    let runtimeRoot = resourceURL
      .appending(path: "runtime", directoryHint: .isDirectory)
    let sidecarScript = runtimeRoot
      .appending(path: "dist-sidecar", directoryHint: .isDirectory)
      .appending(path: "sidecar.cjs")

    guard FileManager.default.fileExists(atPath: sidecarScript.path) else {
      return nil
    }

    return runtimeRoot
  }

  private func bundledNodeExecutableURL() -> URL? {
    guard let executableURL = Bundle.main.executableURL else {
      return nil
    }

    let nodeURL = executableURL.deletingLastPathComponent().appending(path: "JarveyNode")
    guard FileManager.default.isExecutableFile(atPath: nodeURL.path) else {
      return nil
    }

    return nodeURL
  }

  private func hostWorkingDirectory() -> URL {
    if let fromArguments = projectRootArgument(), !fromArguments.isEmpty {
      return URL(fileURLWithPath: fromArguments, isDirectory: true)
    }

    if let override = ProcessInfo.processInfo.environment["JARVEY_PROJECT_ROOT"], !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }

    return FileManager.default.homeDirectoryForCurrentUser
  }

  private func developmentProjectRoot() -> URL {
    let fileManager = FileManager.default
    let candidates = [
      URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true),
      URL(fileURLWithPath: CommandLine.arguments[0], isDirectory: false).deletingLastPathComponent(),
      Bundle.main.bundleURL.deletingLastPathComponent()
    ]

    for candidate in candidates {
      if let resolved = findProjectRoot(startingAt: candidate) {
        return resolved
      }
    }

    return URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
  }

  private func findProjectRoot(startingAt startURL: URL) -> URL? {
    let fileManager = FileManager.default
    var currentURL = startURL.standardizedFileURL

    for _ in 0 ..< 8 {
      let packageJSON = currentURL.appending(path: "package.json")
      let packageSwift = currentURL.appending(path: "Package.swift")
      if fileManager.fileExists(atPath: packageJSON.path) || fileManager.fileExists(atPath: packageSwift.path) {
        return currentURL
      }

      let parentURL = currentURL.deletingLastPathComponent()
      if parentURL.path == currentURL.path {
        break
      }
      currentURL = parentURL
    }

    return nil
  }

  private func projectRootArgument() -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--project-root"), index + 1 < arguments.count else {
      return nil
    }
    return arguments[index + 1]
  }
}

enum SidecarStartupError: LocalizedError {
  case missingSidecarBinary(String)
  case failedToBecomeHealthy
  case staleUnauthorizedSidecar

  var errorDescription: String? {
    switch self {
    case .missingSidecarBinary(let path):
      return "Missing sidecar runtime at \(path). Run `npm run build` first."
    case .failedToBecomeHealthy:
      return "The Jarvis sidecar did not become healthy in time."
    case .staleUnauthorizedSidecar:
      return "A sidecar from a previous session is still running on port \(LocalEndpoints.sidecarPort). Quit it and relaunch Jarvis."
    }
  }
}
