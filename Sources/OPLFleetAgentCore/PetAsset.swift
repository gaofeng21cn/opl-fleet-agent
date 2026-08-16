import CryptoKit
import Foundation

public struct AmbientOpsPetAsset: Equatable, Sendable {
  public let definition: AmbientOpsPetDefinition
  public let data: Data
}

public actor AmbientOpsPetAssetCatalog {
  public static let maximumAssetBytes = 8 * 1_024 * 1_024

  private struct Manifest: Decodable {
    let id: String
    let displayName: String
    let spriteVersionNumber: Int
    let spritesheetPath: String
  }

  private struct FileMetadata: Equatable {
    let size: Int
    let modifiedAt: Date
  }

  private struct Fingerprint: Equatable {
    let manifest: FileMetadata
    let spritesheet: FileMetadata
  }

  private struct CachedAsset {
    let directory: URL
    let fingerprint: Fingerprint
    let asset: AmbientOpsPetAsset
  }

  private let petsRoot: URL
  private let preferredPetID: String?
  private var cache: CachedAsset?

  public init(codexHome: URL, preferredPetID: String? = nil) {
    petsRoot = codexHome.appendingPathComponent("pets", isDirectory: true)
    self.preferredPetID = preferredPetID?.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  public func currentAsset() -> AmbientOpsPetAsset? {
    for directory in candidateDirectories() {
      if let asset = loadAsset(from: directory) {
        return asset
      }
    }
    cache = nil
    return nil
  }

  private func candidateDirectories() -> [URL] {
    let fileManager = FileManager.default
    if let preferredPetID {
      guard Self.isValidPetID(preferredPetID) else { return [] }
      let directory = petsRoot.appendingPathComponent(preferredPetID, isDirectory: true)
      return Self.isSafeDirectory(directory) ? [directory] : []
    }

    guard
      let directories = try? fileManager.contentsOfDirectory(
        at: petsRoot,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }
    return
      directories
      .filter(Self.isSafeDirectory)
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func loadAsset(from directory: URL) -> AmbientOpsPetAsset? {
    let directoryID = directory.lastPathComponent
    guard Self.isValidPetID(directoryID) else { return nil }

    let manifestURL = directory.appendingPathComponent("pet.json", isDirectory: false)
    let spritesheetURL = directory.appendingPathComponent(
      "spritesheet.webp", isDirectory: false)
    guard
      let manifestMetadata = Self.fileMetadata(manifestURL, maximumBytes: 64 * 1_024),
      let spritesheetMetadata = Self.fileMetadata(
        spritesheetURL, maximumBytes: Self.maximumAssetBytes)
    else { return nil }

    let fingerprint = Fingerprint(
      manifest: manifestMetadata,
      spritesheet: spritesheetMetadata
    )
    if let cache, cache.directory == directory, cache.fingerprint == fingerprint {
      return cache.asset
    }

    guard
      let manifestData = try? Data(contentsOf: manifestURL, options: [.mappedIfSafe]),
      let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData),
      manifest.id == directoryID,
      manifest.spritesheetPath == "spritesheet.webp",
      let spritesheet = try? Data(contentsOf: spritesheetURL, options: [.mappedIfSafe]),
      Self.isWebP(spritesheet)
    else { return nil }

    let assetHash = SHA256.hash(data: spritesheet)
      .map { String(format: "%02x", $0) }
      .joined()
    guard
      let definition = try? AmbientOpsPetDefinition(
        id: manifest.id,
        displayName: manifest.displayName,
        spriteVersionNumber: manifest.spriteVersionNumber,
        assetHash: assetHash
      )
    else { return nil }
    let asset = AmbientOpsPetAsset(definition: definition, data: spritesheet)
    cache = CachedAsset(directory: directory, fingerprint: fingerprint, asset: asset)
    return asset
  }

  private static func isSafeDirectory(_ url: URL) -> Bool {
    guard
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    else { return false }
    return values.isDirectory == true && values.isSymbolicLink != true
  }

  private static func fileMetadata(_ url: URL, maximumBytes: Int) -> FileMetadata? {
    guard
      let values = try? url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
      ]),
      values.isRegularFile == true,
      values.isSymbolicLink != true,
      let size = values.fileSize,
      size > 0,
      size <= maximumBytes,
      let modifiedAt = values.contentModificationDate
    else { return nil }
    return FileMetadata(size: size, modifiedAt: modifiedAt)
  }

  private static func isValidPetID(_ value: String) -> Bool {
    value.range(
      of: #"^[a-z0-9][a-z0-9._-]{0,79}$"#,
      options: .regularExpression
    ) != nil
  }

  private static func isWebP(_ data: Data) -> Bool {
    guard data.count >= 12 else { return false }
    guard data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WEBP".utf8) else {
      return false
    }
    let declaredSize =
      UInt32(data[4])
      | UInt32(data[5]) << 8
      | UInt32(data[6]) << 16
      | UInt32(data[7]) << 24
    return UInt64(declaredSize) + 8 == UInt64(data.count)
  }
}
