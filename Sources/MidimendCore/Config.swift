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

/// Where parameter feedback goes: events a DAW sends to a virtual output's
/// paired destination (e.g. MainStage's "Send Value to") are forwarded to
/// these hardware destinations. `"all"` mirrors the omitted-`inputs` rule:
/// every hardware destination except ignored ones and our own virtual ports.
public enum FeedbackSpec: Equatable, Sendable, Codable {
    case all
    case devices([EndpointSpec])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let devices = try? container.decode([EndpointSpec].self) {
            self = .devices(devices)
        } else {
            let string = try container.decode(String.self)
            guard string == "all" else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: #""feedback" must be "all" or a list of { "hardware": … } entries"#
                )
            }
            self = .all
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .all: try container.encode("all")
        case .devices(let devices): try container.encode(devices)
        }
    }
}

public struct MIDISetup: Codable, Equatable, Sendable {
    /// nil (key omitted) means: connect all hardware inputs except ignored
    /// ones and our own virtual ports.
    public var inputs: [EndpointSpec]?
    public var outputs: [EndpointSpec]
    /// nil (key omitted) or an empty list means: no feedback path, and no
    /// paired virtual destinations are created.
    public var feedback: FeedbackSpec?
    /// Devices to leave alone entirely (same substring matching as
    /// `hardware`) — e.g. a controller's DAW-control port.
    public var ignore: [String]?

    public init(
        inputs: [EndpointSpec]? = nil,
        outputs: [EndpointSpec],
        feedback: FeedbackSpec? = nil,
        ignore: [String]? = nil
    ) {
        self.inputs = inputs
        self.outputs = outputs
        self.feedback = feedback
        self.ignore = ignore
    }
}

public struct Config: Codable, Sendable {
    /// Path to the processing script, absolute or relative to the config file.
    public var script: String
    public var midi: MIDISetup
    /// Parameter values by PluginParameters name. Menu parameters accept the
    /// valueStrings entry as a string; checkboxes accept booleans.
    public var parameters: [String: ParameterValue]?
    /// Opt-in: while set, incoming MIDI keeps the display awake (defers the
    /// screensaver/display sleep) for as long as someone keeps playing. Absent
    /// or false means the machine sleeps on its normal schedule.
    public var keepAwake: Bool? = nil

    /// The well-known config location used when midimend is started without
    /// arguments (e.g. by `brew services`): visible in Finder, next to the
    /// user's scripts, in the folder musicians already know from
    /// Logic/MainStage (~/Music/Audio Music Apps).
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/Midimend/config.json")
    }

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
