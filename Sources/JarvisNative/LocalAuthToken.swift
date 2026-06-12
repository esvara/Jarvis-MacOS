import Foundation
import Security

enum LocalAuthToken {
  static func generate(byteCount: Int = 32) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    if status == errSecSuccess {
      return bytes.map { String(format: "%02x", $0) }.joined()
    }

    return UUID().uuidString + UUID().uuidString
  }
}
