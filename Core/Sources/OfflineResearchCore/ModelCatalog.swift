import Foundation

/// Mirror of `App/Resources/models.json`, the single source of truth shared with
/// `Scripts/fetch_model.sh` and the README. The app never trusts the network for
/// this file: it ships inside the bundle, so the profile list and checksums are
/// auditable without a connection.
public struct ModelCatalog: Codable, Equatable {
    public struct Profile: Codable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let family: String
        public let parameters: String
        public let quantization: String
        public let filename: String
        public let sizeBytes: Int64
        public let sha256: String
        public let url: String
        public let contextTrain: Int
        public let recommendedContext: Int
        public let ramEstimateMB: Int
        public let license: String
        public let notes: String

        enum CodingKeys: String, CodingKey {
            case id, name, family, parameters, quantization, filename
            case sizeBytes = "size_bytes"
            case sha256, url
            case contextTrain = "context_train"
            case recommendedContext = "recommended_context"
            case ramEstimateMB = "ram_estimate_mb"
            case license, notes
        }

        public var sizeDescription: String {
            ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }
    }

    public let schema: Int
    public let `default`: String
    public let models: [Profile]

    public var defaultProfile: Profile? {
        models.first { $0.id == self.default }
    }

    public func profile(id: String) -> Profile? {
        models.first { $0.id == id }
    }

    /// Structural validation performed at load time and in tests. Returns a list
    /// of human-readable problems; an empty list means the catalog is usable.
    public func validate() -> [String] {
        var problems: [String] = []
        if schema != 1 { problems.append("unexpected schema \(schema)") }
        if models.isEmpty { problems.append("catalog has no models") }
        if !models.contains(where: { $0.id == self.default }) {
            problems.append("default '\(self.default)' is not in the catalog")
        }
        var seen = Set<String>()
        for model in models {
            if !seen.insert(model.id).inserted { problems.append("duplicate id \(model.id)") }
            if model.sha256.count != 64 || !model.sha256.allSatisfy({ $0.isHexDigit }) {
                problems.append("\(model.id): sha256 is not 64 hex characters")
            }
            if model.sizeBytes <= 0 { problems.append("\(model.id): size_bytes must be positive") }
            if !model.filename.hasSuffix(".gguf") { problems.append("\(model.id): filename must end in .gguf") }
            if model.recommendedContext < 512 { problems.append("\(model.id): recommended_context too small") }
            if let url = URL(string: model.url), url.scheme != "https" {
                problems.append("\(model.id): url must be https")
            } else if URL(string: model.url) == nil {
                problems.append("\(model.id): url is not parseable")
            }
            if model.quantization.isEmpty { problems.append("\(model.id): missing quantization") }
        }
        return problems
    }

    public static func decode(_ data: Data) throws -> ModelCatalog {
        let decoder = JSONDecoder()
        let catalog = try decoder.decode(ModelCatalog.self, from: data)
        let problems = catalog.validate()
        if !problems.isEmpty {
            throw CatalogError.invalid(problems)
        }
        return catalog
    }

    public enum CatalogError: LocalizedError {
        case invalid([String])
        public var errorDescription: String? {
            switch self {
            case .invalid(let problems):
                return "models.json is invalid: " + problems.joined(separator: "; ")
            }
        }
    }
}

/// Decoding-free defaults so the app can boot even if the bundled JSON is broken.
public enum ModelCatalogFallback {
    public static func catalog() -> ModelCatalog {
        let profile = ModelCatalog.Profile(
            id: "qwen2.5-1.5b-instruct-q4_k_m",
            name: "Qwen2.5 1.5B Instruct (Q4_K_M)",
            family: "Qwen2.5",
            parameters: "1.5B",
            quantization: "Q4_K_M",
            filename: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
            sizeBytes: 1_117_320_736,
            sha256: "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e",
            url: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf",
            contextTrain: 32768,
            recommendedContext: 4096,
            ramEstimateMB: 2048,
            license: "Apache-2.0",
            notes: "Fallback definition; models.json was unreadable."
        )
        return ModelCatalog(schema: 1, default: profile.id, models: [profile])
    }
}
