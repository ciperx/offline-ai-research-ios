import Foundation
import CryptoKit

/// Owns the on-device GGUF files.
///
/// Files live in `Application Support/Models`, which is inside the app sandbox
/// and backed up unless the user disables it. Two ways in:
///   * Files app / AirDrop -> Documents (UIFileSharingEnabled), then "Import"
///   * `xcrun devicectl device copy` during development
///
/// Every import is hashed with SHA-256 and compared against `models.json`
/// before the file is moved into place, so a truncated download can never be
/// loaded as a model.
final class ModelStore {

    struct InstalledModel: Identifiable, Equatable {
        let profile: ModelCatalog.Profile
        let url: URL
        let verified: Bool
        var id: String { profile.id }
    }

    private let fileManager = FileManager.default
    let catalog: ModelCatalog
    let directory: URL

    init(catalog: ModelCatalog) {
        self.catalog = catalog
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("Models", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Discovery

    func installedModels() -> [InstalledModel] {
        catalog.models.compactMap { profile in
            let url = directory.appendingPathComponent(profile.filename)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            // A size match is a cheap pre-check; the full hash runs on import and
            // on demand from Settings ("Verify").
            return InstalledModel(profile: profile, url: url, verified: size == profile.sizeBytes)
        }
    }

    func path(for profile: ModelCatalog.Profile) -> URL {
        directory.appendingPathComponent(profile.filename)
    }

    func installedPath(for modelID: String?) -> String? {
        guard let modelID, let profile = catalog.profile(id: modelID) else { return nil }
        let url = path(for: profile)
        return fileManager.fileExists(atPath: url.path) ? url.path : nil
    }

    /// First installed model in catalog order (default first), used when the
    /// user has not chosen one explicitly.
    func firstAvailableModelID() -> String? {
        let installed = Set(installedModels().map(\.profile.id))
        if installed.contains(catalog.default) { return catalog.default }
        return catalog.models.first { installed.contains($0.id) }?.id
    }

    func freeDiskSpace() -> Int64 {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: - Import

    enum ImportError: LocalizedError {
        case accessDenied
        case checksumMismatch(expected: String, actual: String)
        case sizeMismatch(expected: Int64, actual: Int64)
        case unknownProfile(String)
        case notEnoughSpace(needed: Int64, available: Int64)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "Could not read the selected file. Try copying it into the app's Documents folder instead."
            case .checksumMismatch(let expected, let actual):
                return "SHA-256 mismatch. Expected \(expected.prefix(12))…, got \(actual.prefix(12))…. The file is corrupt or a different quantisation."
            case .sizeMismatch(let expected, let actual):
                return "Size mismatch: expected \(expected) bytes, file has \(actual)."
            case .unknownProfile(let name):
                return "No catalog entry matches \(name). Add it to models.json first."
            case .notEnoughSpace(let needed, let available):
                return "Not enough disk space: need \(needed / 1_000_000) MB, \(available / 1_000_000) MB available."
            }
        }
    }

    /// Copies a user-selected file into the sandbox and verifies it.
    func importModel(from source: URL, profileID: String? = nil) throws -> InstalledModel {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        guard fileManager.isReadableFile(atPath: source.path) else { throw ImportError.accessDenied }

        let profile = try resolveProfile(for: source, explicitID: profileID)
        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if size != profile.sizeBytes {
            throw ImportError.sizeMismatch(expected: profile.sizeBytes, actual: size)
        }
        let available = freeDiskSpace()
        if available > 0, available < size + 64_000_000 {
            throw ImportError.notEnoughSpace(needed: size, available: available)
        }

        let destination = path(for: profile)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)

        let digest = try Self.sha256(of: destination)
        guard digest == profile.sha256 else {
            try? fileManager.removeItem(at: destination)
            throw ImportError.checksumMismatch(expected: profile.sha256, actual: digest)
        }
        return InstalledModel(profile: profile, url: destination, verified: true)
    }

    /// Full hash check, used by the "Verify" button.
    func verify(_ profile: ModelCatalog.Profile) throws -> Bool {
        let url = path(for: profile)
        guard fileManager.fileExists(atPath: url.path) else { return false }
        return try Self.sha256(of: url) == profile.sha256
    }

    func delete(_ profile: ModelCatalog.Profile) throws {
        let url = path(for: profile)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func resolveProfile(for source: URL, explicitID: String?) throws -> ModelCatalog.Profile {
        if let explicitID, let profile = catalog.profile(id: explicitID) { return profile }
        let name = source.lastPathComponent.lowercased()
        if let exact = catalog.models.first(where: { $0.filename.lowercased() == name }) { return exact }
        if let fuzzy = catalog.models.first(where: { name.contains($0.quantization.lowercased()) && name.contains($0.parameters.lowercased()) }) {
            return fuzzy
        }
        throw ImportError.unknownProfile(source.lastPathComponent)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = try? handle.read(upToCount: 4 << 20)
            guard let chunk, !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
