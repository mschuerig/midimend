/// Applies the config's device-selection rules to endpoint display names:
/// explicit `hardware` patterns, default-all-inputs when `inputs` is
/// omitted, and the `ignore` list, which wins over both. Pure — MIDIIO and
/// `--list-devices` share it.
public struct EndpointSelection: Sendable {
    public enum Verdict: Equatable, Sendable {
        /// pattern is nil when connected by default-all-inputs mode.
        case connected(pattern: String?)
        case ignored(pattern: String)
        case notMatched
    }

    /// nil = default-all-inputs mode.
    private let inputPatterns: [String]?
    private let outputPatterns: [String]
    private let ignorePatterns: [String]

    public init(setup: MIDISetup) {
        inputPatterns = setup.inputs.map { $0.compactMap(\.hardware) }
        outputPatterns = setup.outputs.compactMap(\.hardware)
        ignorePatterns = setup.ignore ?? []
    }

    public func input(_ name: String) -> Verdict {
        if let pattern = ignoreMatch(name) { return .ignored(pattern: pattern) }
        guard let patterns = inputPatterns else { return .connected(pattern: nil) }
        if let pattern = patterns.first(where: { midiNameMatches(name, pattern: $0) }) {
            return .connected(pattern: pattern)
        }
        return .notMatched
    }

    public func output(_ name: String) -> Verdict {
        if let pattern = ignoreMatch(name) { return .ignored(pattern: pattern) }
        if let pattern = outputPatterns.first(where: { midiNameMatches(name, pattern: $0) }) {
            return .connected(pattern: pattern)
        }
        return .notMatched
    }

    /// Configured patterns that no present, non-ignored device satisfies —
    /// the ones worth a diagnosis message.
    public func unmatchedInputPatterns(among names: [String]) -> [String] {
        unmatched(inputPatterns ?? [], among: names)
    }

    public func unmatchedOutputPatterns(among names: [String]) -> [String] {
        unmatched(outputPatterns, among: names)
    }

    private func unmatched(_ patterns: [String], among names: [String]) -> [String] {
        patterns.filter { pattern in
            !names.contains { name in
                midiNameMatches(name, pattern: pattern) && ignoreMatch(name) == nil
            }
        }
    }

    private func ignoreMatch(_ name: String) -> String? {
        ignorePatterns.first { midiNameMatches(name, pattern: $0) }
    }
}
