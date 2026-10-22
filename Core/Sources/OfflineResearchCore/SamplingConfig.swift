import Foundation

/// Decoding parameters. Stored per model profile in UserDefaults; deliberately
/// small surface because every knob is a way to make a 1.5B model worse.
public struct SamplingConfig: Codable, Equatable {
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    public var minP: Double
    public var repeatPenalty: Double
    public var repeatLastN: Int
    public var maxTokens: Int
    public var seed: UInt32
    public var stopStrings: [String]

    public init(temperature: Double = 0.3,
                topP: Double = 0.9,
                topK: Int = 40,
                minP: Double = 0.05,
                repeatPenalty: Double = 1.1,
                repeatLastN: Int = 256,
                maxTokens: Int = 512,
                seed: UInt32 = 0xDEADBEEF,
                stopStrings: [String] = ["\nQuestion:", "\nSources:", "<|im_end|>"]) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.repeatPenalty = repeatPenalty
        self.repeatLastN = repeatLastN
        self.maxTokens = maxTokens
        self.seed = seed
        self.stopStrings = stopStrings
    }

    /// Greedy-ish settings used by the benchmark harness so runs are comparable.
    public static let deterministic = SamplingConfig(temperature: 0.0, topP: 1.0, topK: 1,
                                                     minP: 0.0, repeatPenalty: 1.0,
                                                     maxTokens: 512, seed: 42)

    public func clamped() -> SamplingConfig {
        var copy = self
        copy.temperature = min(max(temperature, 0), 2)
        copy.topP = min(max(topP, 0.05), 1)
        copy.topK = min(max(topK, 1), 200)
        copy.minP = min(max(minP, 0), 0.5)
        copy.repeatPenalty = min(max(repeatPenalty, 1), 1.5)
        copy.maxTokens = min(max(maxTokens, 32), 4096)
        return copy
    }
}
