import CryptoKit
import Foundation
import XCTest

@testable import OPLFleetAgentCore

final class PetAssetTests: XCTestCase {
  func testDiscoversLocalPetAndCachesByMetadata() async throws {
    let root = try makeTemporaryCodexHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let spritesheet = webP(payload: Data("first".utf8))
    let paths = try writePet(in: root, id: "build-fox", spritesheet: spritesheet)
    let originalDate = Date(timeIntervalSince1970: 1_000)
    try FileManager.default.setAttributes(
      [.modificationDate: originalDate], ofItemAtPath: paths.spritesheet.path)
    let catalog = AmbientOpsPetAssetCatalog(codexHome: root)

    let discoveredFirst = await catalog.currentAsset()
    let first = try XCTUnwrap(discoveredFirst)
    XCTAssertEqual(first.definition.id, "build-fox")
    XCTAssertEqual(first.definition.displayName, "Build Fox")
    XCTAssertEqual(first.definition.spriteVersionNumber, 2)
    XCTAssertEqual(first.definition.assetHash, sha256(spritesheet))

    let sameSizeReplacement = webP(payload: Data("other".utf8))
    XCTAssertEqual(sameSizeReplacement.count, spritesheet.count)
    try sameSizeReplacement.write(to: paths.spritesheet)
    try FileManager.default.setAttributes(
      [.modificationDate: originalDate], ofItemAtPath: paths.spritesheet.path)

    let discoveredCached = await catalog.currentAsset()
    let cached = try XCTUnwrap(discoveredCached)
    XCTAssertEqual(cached.definition.assetHash, first.definition.assetHash)

    try FileManager.default.setAttributes(
      [.modificationDate: originalDate.addingTimeInterval(2)],
      ofItemAtPath: paths.spritesheet.path)
    let discoveredUpdated = await catalog.currentAsset()
    let updated = try XCTUnwrap(discoveredUpdated)
    XCTAssertEqual(updated.definition.assetHash, sha256(sameSizeReplacement))
    XCTAssertNotEqual(updated.definition.assetHash, first.definition.assetHash)
  }

  func testRejectsEscapingManifestAndOversizedAsset() async throws {
    let escapingRoot = try makeTemporaryCodexHome()
    defer { try? FileManager.default.removeItem(at: escapingRoot) }
    _ = try writePet(
      in: escapingRoot,
      id: "unsafe",
      spritesheet: webP(payload: Data("x".utf8)),
      spritesheetPath: "../secret.webp"
    )
    let escapingAsset = await AmbientOpsPetAssetCatalog(
      codexHome: escapingRoot
    ).currentAsset()
    XCTAssertNil(escapingAsset)

    let oversizedRoot = try makeTemporaryCodexHome()
    defer { try? FileManager.default.removeItem(at: oversizedRoot) }
    let oversized = Data(
      repeating: 0,
      count: AmbientOpsPetAssetCatalog.maximumAssetBytes + 1)
    _ = try writePet(in: oversizedRoot, id: "too-large", spritesheet: oversized)
    let oversizedAsset = await AmbientOpsPetAssetCatalog(
      codexHome: oversizedRoot
    ).currentAsset()
    XCTAssertNil(oversizedAsset)
  }

  func testIgnoresPetMetadataFieldsOutsideAllowlist() async throws {
    let root = try makeTemporaryCodexHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("pets/private-owl", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let manifest = """
      {
        "id": "private-owl",
        "displayName": "Private Owl",
        "spriteVersionNumber": 1,
        "spritesheetPath": "spritesheet.webp",
        "prompt": "never transmit me",
        "response": "nor me",
        "sessionPath": "/Users/private/.codex/sessions"
      }
      """
    try Data(manifest.utf8).write(to: directory.appendingPathComponent("pet.json"))
    try webP(payload: Data("safe".utf8)).write(
      to: directory.appendingPathComponent("spritesheet.webp"))

    let discoveredAsset = await AmbientOpsPetAssetCatalog(codexHome: root).currentAsset()
    let asset = try XCTUnwrap(discoveredAsset)
    let identity = try AmbientOpsMachineIdentity(
      machineID: "private-mac", machineName: "Private Mac", platform: "macOS")
    var tracker = AmbientOpsPetTracker()
    let usage = UsageSnapshot.empty(at: Date(), status: .ready)
    let snapshot = AmbientOpsAgentSnapshot(
      usage: usage,
      identity: identity,
      pet: tracker.snapshot(definition: asset.definition, usage: usage)
    )
    let data = try JSONEncoder().encode(snapshot)
    let payload = try XCTUnwrap(String(data: data, encoding: .utf8))

    XCTAssertFalse(payload.contains("never transmit me"))
    XCTAssertFalse(payload.contains("nor me"))
    XCTAssertFalse(payload.contains("/Users/"))
    XCTAssertFalse(payload.contains("spritesheetPath"))
  }

  private func makeTemporaryCodexHome() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  @discardableResult
  private func writePet(
    in root: URL,
    id: String,
    spritesheet: Data,
    spritesheetPath: String = "spritesheet.webp"
  ) throws -> (manifest: URL, spritesheet: URL) {
    let directory = root.appendingPathComponent("pets/\(id)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let manifestURL = directory.appendingPathComponent("pet.json")
    let spritesheetURL = directory.appendingPathComponent("spritesheet.webp")
    let manifest = """
      {
        "id": "\(id)",
        "displayName": "\(id == "build-fox" ? "Build Fox" : id)",
        "spriteVersionNumber": 2,
        "spritesheetPath": "\(spritesheetPath)"
      }
      """
    try Data(manifest.utf8).write(to: manifestURL)
    try spritesheet.write(to: spritesheetURL)
    return (manifestURL, spritesheetURL)
  }

  private func webP(payload: Data) -> Data {
    var data = Data("RIFF".utf8)
    var size = UInt32(payload.count + 4).littleEndian
    data.append(Data(bytes: &size, count: MemoryLayout<UInt32>.size))
    data.append(Data("WEBP".utf8))
    data.append(payload)
    return data
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
