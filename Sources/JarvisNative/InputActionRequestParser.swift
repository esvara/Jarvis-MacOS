import Foundation

struct InputActionRequestParser {
  /// Largest accepted request body. Requests only carry JSON (prompts, click
  /// targets); anything bigger is a bug or an attempt to exhaust memory.
  /// Keep in sync with MAX_REQUEST_BODY_BYTES in src/sidecar/server.ts —
  /// both loopback servers share the cap.
  static let maxBodyBytes = 2_000_000

  static func parse(_ data: Data) throws -> InputActionRequestParseResult {
    guard let separatorRange = data.range(of: Data("\r\n\r\n".utf8)) else {
      return .incomplete
    }

    let headerData = data[..<separatorRange.lowerBound]
    guard let headerString = String(data: headerData, encoding: .utf8) else {
      throw InputActionRequestParserError.invalidEncoding
    }

    let lines = headerString.components(separatedBy: "\r\n")
    guard let requestLine = lines.first, !requestLine.isEmpty else {
      throw InputActionRequestParserError.invalidRequestLine
    }

    let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    guard requestParts.count >= 2 else {
      throw InputActionRequestParserError.invalidRequestLine
    }

    let method = String(requestParts[0]).uppercased()
    let rawPath = String(requestParts[1])
    let pathParts = rawPath.split(separator: "?", maxSplits: 1)
    let path = String(pathParts.first ?? "")
    let query = pathParts.count > 1 ? String(pathParts[1]) : ""
    let headers = parseHeaders(Array(lines.dropFirst()))
    let queryApp = queryValue(query, name: "app")

    switch (method, path) {
    case ("GET", "/health"):
      return .ready(.health)
    case ("GET", "/screenshot"):
      return .ready(.screenshot(authorization: headers["authorization"]))
    case ("GET", "/codex/status"), ("GET", "/agent/status"):
      return .ready(.agentStatus(app: queryApp ?? "codex", authorization: headers["authorization"]))
    case ("GET", "/codex/read"), ("GET", "/agent/read"):
      return .ready(.agentRead(app: queryApp ?? "codex", authorization: headers["authorization"]))
    case ("GET", "/app/read"):
      return .ready(.appRead(app: queryApp ?? "", authorization: headers["authorization"]))
    case ("POST", "/emergency-stop"):
      return .ready(.emergencyStop(authorization: headers["authorization"]))
    case ("POST", "/resume-actions"):
      return .ready(.resumeActions(authorization: headers["authorization"]))
    case ("POST", "/codex/send-prompt"), ("POST", "/agent/send-prompt"):
      guard let body = try bodyData(from: data, separatorRange: separatorRange, headers: headers) else {
        return .incomplete
      }
      let decoder = JSONDecoder()
      guard let payload = try? decoder.decode(AgentPromptBody.self, from: body) else {
        throw InputActionRequestParserError.invalidJSON
      }
      return .ready(.agentSendPrompt(
        payload.prompt,
        app: payload.app ?? "codex",
        authorization: headers["authorization"]))
    case ("POST", "/app/paste"):
      guard let body = try bodyData(from: data, separatorRange: separatorRange, headers: headers) else {
        return .incomplete
      }
      let decoder = JSONDecoder()
      guard let payload = try? decoder.decode(AppPasteBody.self, from: body) else {
        throw InputActionRequestParserError.invalidJSON
      }
      return .ready(.appPaste(payload, authorization: headers["authorization"]))
    case ("POST", "/app/quit"):
      guard let body = try bodyData(from: data, separatorRange: separatorRange, headers: headers) else {
        return .incomplete
      }
      let decoder = JSONDecoder()
      guard let payload = try? decoder.decode(AppQuitBody.self, from: body) else {
        throw InputActionRequestParserError.invalidJSON
      }
      return .ready(.appQuit(payload, authorization: headers["authorization"]))
    case ("POST", "/app/click"):
      guard let body = try bodyData(from: data, separatorRange: separatorRange, headers: headers) else {
        return .incomplete
      }
      let decoder = JSONDecoder()
      guard let payload = try? decoder.decode(AppClickBody.self, from: body) else {
        throw InputActionRequestParserError.invalidJSON
      }
      return .ready(.appClick(payload, authorization: headers["authorization"]))
    case ("POST", "/action"):
      guard let body = try bodyData(from: data, separatorRange: separatorRange, headers: headers) else {
        return .incomplete
      }
      let decoder = JSONDecoder()
      guard let action = try? decoder.decode(InputAction.self, from: body) else {
        throw InputActionRequestParserError.invalidJSON
      }
      return .ready(.action(action, authorization: headers["authorization"]))
    case ("GET", _), ("POST", _):
      throw InputActionRequestParserError.unsupportedPath(path)
    default:
      throw InputActionRequestParserError.unsupportedMethod(method)
    }
  }

  private static func bodyData(
    from data: Data,
    separatorRange: Range<Data.Index>,
    headers: [String: String]
  ) throws -> Data? {
    guard let contentLengthValue = headers["content-length"] else {
      throw InputActionRequestParserError.missingContentLength
    }
    guard let contentLength = Int(contentLengthValue), contentLength >= 0 else {
      throw InputActionRequestParserError.invalidContentLength
    }
    guard contentLength <= maxBodyBytes else {
      throw InputActionRequestParserError.payloadTooLarge
    }

    let bodyStart = separatorRange.upperBound
    let expectedBodyEnd = data.index(bodyStart, offsetBy: contentLength, limitedBy: data.endIndex)
    guard let expectedBodyEnd, expectedBodyEnd <= data.endIndex else {
      return nil
    }
    return Data(data[bodyStart..<expectedBodyEnd])
  }

  private static func queryValue(_ query: String, name: String) -> String? {
    guard !query.isEmpty else {
      return nil
    }
    for pair in query.split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1)
      guard parts.count == 2, parts[0] == name.lowercased() || parts[0] == Substring(name) else {
        continue
      }
      let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
      return value.isEmpty ? nil : value
    }
    return nil
  }

  private static func parseHeaders(_ lines: [String]) -> [String: String] {
    var headers: [String: String] = [:]
    for line in lines where !line.isEmpty {
      guard let separatorIndex = line.firstIndex(of: ":") else {
        continue
      }
      let name = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let value = line[line.index(after: separatorIndex)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      headers[name] = value
    }
    return headers
  }
}
