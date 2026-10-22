import Foundation

/// Cheap token estimate used for context budgeting before we own a real tokenizer.
///
/// The llama.cpp tokenizer is available only after a model loads, but the prompt
/// must be assembled (and trimmed) before generation starts. We use a calibrated
/// heuristic and then verify with the real tokenizer inside `LlamaEngine`; if the
/// real count exceeds the budget the engine trims passages and retries once.
public enum TokenEstimator {

    /// English prose averages ~3.6 characters per token for Qwen-family vocabs.
    public static let charsPerToken: Double = 3.6

    public static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let chars = Double(text.count) / charsPerToken
        let words = Double(text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count) * 0.28
        // Punctuation and markup add tokens without adding characters proportionally.
        let marks = Double(text.filter { ".,;:!?()[]{}`#-—\"'".contains($0) }.count) * 0.5
        return max(1, Int((chars * 0.55 + words + marks).rounded(.up)))
    }

    public static func estimate<S: Sequence>(_ texts: S) -> Int where S.Element == String {
        texts.reduce(0) { $0 + estimate($1) }
    }

    /// Greedy trim: keep whole passages while they fit, then stop. Order is
    /// preserved so the highest-scoring passage is never dropped for a lower one.
    public static func trim<T>(_ items: [T], budget: Int, text: (T) -> String) -> [T] {
        guard budget > 0 else { return [] }
        var used = 0
        var kept: [T] = []
        for item in items {
            let cost = estimate(text(item))
            if used + cost > budget { break }
            used += cost
            kept.append(item)
        }
        return kept
    }
}
