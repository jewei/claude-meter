import Foundation
import MeterPlatform

/// Input and output tokens of one Codex usage object.
///
/// Codex fills these from the Responses API `usage`. `cached_input_tokens` and
/// `cache_write_input_tokens` come from `input_tokens_details` and are parts of
/// `input_tokens`; `reasoning_output_tokens` is part of `output_tokens`. So input plus output
/// counts every token once, and the detail counts are never added.
struct CodexTokenCounts: Hashable, Sendable {
    static let zero = CodexTokenCounts(input: 0, output: 0)

    let input: Int64
    let output: Int64

    /// Input plus output, or nil when the sum does not fit in `Int64`.
    var total: Int64? { TokenRecord.sum([input, output]) }

    /// True when both counts are at least those of `other`.
    func covers(_ other: CodexTokenCounts) -> Bool {
        input >= other.input && output >= other.output
    }

    /// The growth from `other`, never below zero.
    func subtracting(_ other: CodexTokenCounts) -> CodexTokenCounts {
        CodexTokenCounts(
            input: max(0, input - other.input), output: max(0, output - other.output))
    }

    func maximum(_ other: CodexTokenCounts) -> CodexTokenCounts {
        CodexTokenCounts(input: max(input, other.input), output: max(output, other.output))
    }

    func minimum(_ other: CodexTokenCounts) -> CodexTokenCounts {
        CodexTokenCounts(input: min(input, other.input), output: min(output, other.output))
    }

    /// The sum, or nil when a count or the total does not fit in `Int64`.
    func adding(_ other: CodexTokenCounts) -> CodexTokenCounts? {
        guard let input = TokenRecord.sum([input, other.input]),
            let output = TokenRecord.sum([output, other.output]),
            TokenRecord.sum([input, output]) != nil
        else { return nil }
        return CodexTokenCounts(input: input, output: output)
    }
}
