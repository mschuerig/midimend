import Foundation

/// Renders a config-file skeleton for a script: a placeholder hardware
/// input, the standard virtual output, feedback to all devices (explicit,
/// so the behavior is readable in the file), and every configurable
/// parameter with its default value, in script order.
public enum ConfigTemplate {
    public static let inputPlaceholder = "your controller's name — run: midimend --list-devices"
    /// Plain "Midimend": the port is a name-paired source/destination duo
    /// (parameter feedback), so a direction suffix would misname one side.
    public static let virtualOutputName = "Midimend"

    public static func render(scriptPath: String, parameters: [ParameterDefinition]) -> String {
        var lines = [
            "{",
            "  \"script\": \(jsonString(scriptPath)),",
            "  \"midi\": {",
            "    \"inputs\": [",
            "      { \"hardware\": \(jsonString(inputPlaceholder)) }",
            "    ],",
            "    \"outputs\": [",
            "      { \"virtual\": \(jsonString(virtualOutputName)) }",
            "    ],",
            "    \"feedback\": \"all\"",
        ]
        let entries = parameters.compactMap(parameterLine)
        if entries.isEmpty {
            lines.append("  }")
        } else {
            lines.append("  },")
            lines.append("  \"parameters\": {")
            lines.append(entries.joined(separator: ",\n"))
            lines.append("  }")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// The config value for one parameter, or nil for kinds that carry no
    /// configurable value (labels, momentary buttons).
    private static func parameterLine(_ parameter: ParameterDefinition) -> String? {
        let value: String
        switch parameter.type {
        case "text", "momentary":
            return nil
        case "checkbox":
            value = parameter.defaultValue != 0 ? "true" : "false"
        case "menu" where !parameter.valueStrings.isEmpty:
            let index = min(parameter.valueStrings.count - 1,
                            max(0, Int(parameter.defaultValue.rounded())))
            value = jsonString(parameter.valueStrings[index])
        default:
            value = jsonNumber(parameter.defaultValue)
        }
        return "    \(jsonString(parameter.name)): \(value)"
    }

    private static func jsonNumber(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int(value))
        }
        return "\(value)"
    }

    private static func jsonString(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
