import Foundation

public enum MidimendError: Error, CustomStringConvertible, Sendable {
    case config(String)
    case script(String)
    case midi(String, OSStatus)

    public var description: String {
        switch self {
        case .config(let message): return message
        case .script(let message): return message
        case .midi(let message, let status): return "\(message) (OSStatus \(status))"
        }
    }
}

/// A parameter value from the config file: number, string (e.g. a menu entry), or bool.
public enum ParameterValue: Codable, Equatable, Sendable {
    case number(Double)
    case string(String)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}

/// One MIDI endpoint in the config: either a virtual port this app creates,
/// or a hardware/external endpoint matched by (case-insensitive) name substring.
public struct EndpointSpec: Codable, Equatable, Sendable {
    public var virtualName: String?
    public var hardware: String?

    enum CodingKeys: String, CodingKey {
        case virtualName = "virtual"
        case hardware
    }

    public init(virtualName: String? = nil, hardware: String? = nil) {
        self.virtualName = virtualName
        self.hardware = hardware
    }
}

public struct MIDISetup: Codable, Equatable, Sendable {
    public var inputs: [EndpointSpec]
    public var outputs: [EndpointSpec]

    public init(inputs: [EndpointSpec], outputs: [EndpointSpec]) {
        self.inputs = inputs
        self.outputs = outputs
    }
}

public struct Config: Codable, Sendable {
    /// Path to the processing script, absolute or relative to the config file.
    public var script: String
    public var midi: MIDISetup
    /// Parameter values by PluginParameters name. Menu parameters accept the
    /// valueStrings entry as a string; checkboxes accept booleans.
    public var parameters: [String: ParameterValue]?

    public static func load(from url: URL) throws -> Config {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MidimendError.config("cannot read config \(url.path): \(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw MidimendError.config("cannot parse config \(url.path): \(error)")
        }
    }

    public func scriptURL(relativeTo configURL: URL) -> URL {
        let expanded = (script as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return configURL.deletingLastPathComponent()
            .appendingPathComponent(script).standardizedFileURL
    }
}
