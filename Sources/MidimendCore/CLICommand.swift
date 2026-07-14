/// The CLI's argument grammar, pure so it is testable without spawning the
/// binary. main.swift switches over the result; side effects (default-config
/// resolution, printing, exit codes) stay there.
public enum CLICommand: Equatable, Sendable {
    /// configPath nil = run the default config (resolved by the caller).
    case run(configPath: String?, measure: Bool)
    case listDevices(configPath: String?)
    case initTemplate(scriptPath: String)
    case version
    case help
    case usageError

    public static func parse(_ arguments: [String]) -> CLICommand {
        switch arguments.first {
        case nil:
            return .run(configPath: nil, measure: false)
        case "--measure":
            guard arguments.count <= 2 else { return .usageError }
            return .run(configPath: arguments.count == 2 ? arguments[1] : nil, measure: true)
        case "--list-devices":
            guard arguments.count <= 2 else { return .usageError }
            return .listDevices(configPath: arguments.count == 2 ? arguments[1] : nil)
        case "--init":
            guard arguments.count == 2 else { return .usageError }
            return .initTemplate(scriptPath: arguments[1])
        case "--version":
            guard arguments.count == 1 else { return .usageError }
            return .version
        case "-h", "--help":
            guard arguments.count == 1 else { return .usageError }
            return .help
        case let option? where option.hasPrefix("-"):
            return .usageError
        default:
            guard arguments.count == 1 else { return .usageError }
            return .run(configPath: arguments[0], measure: false)
        }
    }
}

/// One --list-devices section as output lines: the title, each device with
/// its verdict annotation, then a diagnosis line per unmatched pattern.
/// verdict nil = no config given (bare listing). `feedback` annotates the
/// destinations section with the feedback-path verdict; only its
/// `.connected` case adds anything (ignores are already annotated by the
/// forward verdict).
public func deviceLines(
    title: String,
    names: [String],
    verdict: ((String) -> EndpointSelection.Verdict)?,
    feedback: ((String) -> EndpointSelection.Verdict)? = nil,
    missing: [String]
) -> [String] {
    var lines = ["\(title):"]
    if names.isEmpty {
        lines.append("  (none)")
    }
    for name in names {
        var annotations: [String] = []
        switch verdict?(name) {
        case .connected(let pattern?):
            annotations.append("matched by \"\(pattern)\"")
        case .connected(nil):
            annotations.append("connected (no \"inputs\" in config: all devices)")
        case .ignored(let pattern):
            annotations.append("ignored by \"\(pattern)\"")
        case .notMatched, nil:
            break
        }
        switch feedback?(name) {
        case .connected(let pattern?):
            annotations.append("feedback (matched by \"\(pattern)\")")
        case .connected(nil):
            annotations.append("feedback (\"feedback\": \"all\")")
        case .ignored, .notMatched, nil:
            break
        }
        if annotations.isEmpty {
            lines.append("  \(name)")
        } else {
            lines.append("  \(name)  — \(annotations.joined(separator: ", "))")
        }
    }
    for pattern in missing {
        lines.append("  (nothing matches \"\(pattern)\")")
    }
    return lines
}
