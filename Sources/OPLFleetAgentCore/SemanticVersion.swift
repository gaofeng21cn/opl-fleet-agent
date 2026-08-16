import Foundation

public struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
  public static let zero = SemanticVersion(major: 0, minor: 0, patch: 0)

  public let major: Int
  public let minor: Int
  public let patch: Int

  public init(major: Int, minor: Int, patch: Int) {
    precondition(major >= 0 && minor >= 0 && patch >= 0)
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  public init?(_ value: String) {
    var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.first == "v" || normalized.first == "V" {
      normalized.removeFirst()
    }

    let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3,
      let major = Int(components[0]),
      let minor = Int(components[1]),
      let patch = Int(components[2]),
      major >= 0,
      minor >= 0,
      patch >= 0
    else {
      return nil
    }

    self.init(major: major, minor: minor, patch: patch)
  }

  public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    if lhs.major != rhs.major { return lhs.major < rhs.major }
    if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
    return lhs.patch < rhs.patch
  }

  public var description: String {
    "\(major).\(minor).\(patch)"
  }
}
