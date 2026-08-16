import Foundation
import OPLFleetAgentCore

@main
struct OPLFleetAgentSnapshotCommand {
  static func main() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())

    if arguments.contains("--help") || arguments.contains("-h") {
      print("Usage: opl-fleet-agent-snapshot [--json]")
      return
    }

    guard arguments.allSatisfy({ $0 == "--json" }) else {
      throw CommandError.invalidArguments
    }

    let snapshot = await SessionScanner().refresh()
    if arguments.contains("--json") {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(
          date.formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true)
          ))
      }
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(snapshot)
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data("\n".utf8))
      return
    }

    print("Status: \(snapshot.status.rawValue)")
    print(
      "1m: \(snapshot.oneMinute.tokensPerSecond.formatted(.number.precision(.fractionLength(1)))) token/s"
    )
    print(
      "5m: \(snapshot.fiveMinutes.tokensPerSecond.formatted(.number.precision(.fractionLength(1)))) token/s"
    )
    print(
      "30m: \(snapshot.thirtyMinutes.tokensPerSecond.formatted(.number.precision(.fractionLength(1)))) token/s"
    )
    print(
      "1h: \(snapshot.oneHour.tokensPerSecond.formatted(.number.precision(.fractionLength(1)))) token/s"
    )
    print("Active sessions: \(snapshot.activeSessions)")
  }
}

private enum CommandError: LocalizedError {
  case invalidArguments

  var errorDescription: String? {
    "Invalid arguments. Use --help for usage."
  }
}
