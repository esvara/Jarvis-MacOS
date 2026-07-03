@testable import JarvisNative
import XCTest

final class InputActionRequestParserTests: XCTestCase {
  func testHealthRequestParsesWithoutBody() throws {
    let request = Data("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)

    XCTAssertEqual(try InputActionRequestParser.parse(request), .ready(.health))
  }

  func testScreenshotRequestParsesWithoutBody() throws {
    let request = Data("GET /screenshot HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)

    XCTAssertEqual(try InputActionRequestParser.parse(request), .ready(.screenshot(authorization: nil)))
  }

  func testCodexStatusRequestParsesWithAuthorization() throws {
    let request = Data("GET /codex/status HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer local\r\n\r\n".utf8)

    XCTAssertEqual(try InputActionRequestParser.parse(request), .ready(.agentStatus(app: "codex", authorization: "Bearer local")))
  }

  func testAgentStatusRequestParsesAppQuery() throws {
    let request = Data("GET /agent/status?app=claude HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer local\r\n\r\n".utf8)

    XCTAssertEqual(try InputActionRequestParser.parse(request), .ready(.agentStatus(app: "claude", authorization: "Bearer local")))
  }

  func testCodexReadRequestParsesWithAuthorization() throws {
    let request = Data("GET /codex/read HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer local\r\n\r\n".utf8)

    XCTAssertEqual(try InputActionRequestParser.parse(request), .ready(.agentRead(app: "codex", authorization: "Bearer local")))
  }

  func testAppReadRequestParsesAppQuery() throws {
    let request = Data("GET /app/read?app=Safari HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer local\r\n\r\n".utf8)

    XCTAssertEqual(try InputActionRequestParser.parse(request), .ready(.appRead(app: "Safari", authorization: "Bearer local")))
  }

  func testAppQuitRequestParsesBody() throws {
    let body = #"{"app":"Notes"}"#
    let headers = [
      "POST /app/quit HTTP/1.1",
      "Host: localhost",
      "Authorization: Bearer local",
      "Content-Type: application/json",
      "Content-Length: \(body.utf8.count)",
      "",
      ""
    ].joined(separator: "\r\n")

    XCTAssertEqual(
      try InputActionRequestParser.parse(Data((headers + body).utf8)),
      .ready(.appQuit(AppQuitBody(app: "Notes"), authorization: "Bearer local")))
  }

  func testActionRequestStaysIncompleteUntilEntireBodyArrives() throws {
    let body = #"{"type":"click","x":10,"y":20,"button":"left"}"#
    let headers = [
      "POST /action HTTP/1.1",
      "Host: localhost",
      "Content-Type: application/json",
      "Content-Length: \(body.utf8.count)",
      "",
      ""
    ].joined(separator: "\r\n")

    let partialRequest = Data((headers + String(body.dropLast(3))).utf8)
    XCTAssertEqual(try InputActionRequestParser.parse(partialRequest), .incomplete)

    let fullRequest = Data((headers + body).utf8)
    XCTAssertEqual(
      try InputActionRequestParser.parse(fullRequest),
      .ready(
        .action(
          InputAction(
            type: .click,
            x: 10,
            y: 20,
            button: .left,
            text: nil,
            keys: nil,
            combo: nil,
            scrollX: nil,
            scrollY: nil,
            fromX: nil,
            fromY: nil,
            toX: nil,
            toY: nil,
            path: nil),
          authorization: nil)))
  }

  func testOversizedContentLengthIsRejected() {
    let request = Data(
      [
        "POST /action HTTP/1.1",
        "Host: localhost",
        "Content-Type: application/json",
        "Content-Length: \(InputActionRequestParser.maxBodyBytes + 1)",
        "",
        ""
      ].joined(separator: "\r\n").utf8)

    XCTAssertThrowsError(try InputActionRequestParser.parse(request)) { error in
      XCTAssertEqual(error as? InputActionRequestParserError, .payloadTooLarge)
    }
  }

  func testMissingContentLengthIsRejected() {
    let request = Data(
      [
        "POST /action HTTP/1.1",
        "Host: localhost",
        "Content-Type: application/json",
        "",
        #"{"type":"move","x":1,"y":2}"#
      ].joined(separator: "\r\n").utf8)

    XCTAssertThrowsError(try InputActionRequestParser.parse(request)) { error in
      XCTAssertEqual(error as? InputActionRequestParserError, .missingContentLength)
    }
  }

  func testCodexSendPromptRequestParsesBody() throws {
    let body = #"{"prompt":"Summarize this project"}"#
    let headers = [
      "POST /codex/send-prompt HTTP/1.1",
      "Host: localhost",
      "Authorization: Bearer local",
      "Content-Type: application/json",
      "Content-Length: \(body.utf8.count)",
      "",
      ""
    ].joined(separator: "\r\n")

    XCTAssertEqual(
      try InputActionRequestParser.parse(Data((headers + body).utf8)),
      .ready(.agentSendPrompt("Summarize this project", app: "codex", authorization: "Bearer local")))
  }

  func testAgentSendPromptRequestParsesAppField() throws {
    let body = #"{"prompt":"Fix the build","app":"claude"}"#
    let headers = [
      "POST /agent/send-prompt HTTP/1.1",
      "Host: localhost",
      "Authorization: Bearer local",
      "Content-Type: application/json",
      "Content-Length: \(body.utf8.count)",
      "",
      ""
    ].joined(separator: "\r\n")

    XCTAssertEqual(
      try InputActionRequestParser.parse(Data((headers + body).utf8)),
      .ready(.agentSendPrompt("Fix the build", app: "claude", authorization: "Bearer local")))
  }
}
