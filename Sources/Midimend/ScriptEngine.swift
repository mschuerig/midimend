import Foundation
import JavaScriptCore

/// One channel-voice MIDI message as raw bytes (status includes the channel nibble).
public struct MIDIEventBytes: Equatable, Sendable {
    public var status: UInt8
    public var data1: UInt8
    public var data2: UInt8

    public init(status: UInt8, data1: UInt8, data2: UInt8) {
        self.status = status
        self.data1 = data1
        self.data2 = data2
    }
}

public struct ParameterDefinition: Sendable {
    public var name: String
    public var type: String
    public var defaultValue: Double
    public var minValue: Double
    public var maxValue: Double
    public var valueStrings: [String]
}

/// Runs one MIDI-processing script in a JavaScriptCore context.
///
/// Not internally synchronized: create it on the queue/thread that will feed it
/// events and never touch it from anywhere else (one script, one context,
/// one thread).
public final class ScriptEngine: @unchecked Sendable {
    public typealias SendHandler = @Sendable (MIDIEventBytes) -> Void
    public typealias TraceHandler = @Sendable (String) -> Void
    /// Schedules `action` after `delayMs` milliseconds on the engine's queue.
    public typealias Scheduler = @Sendable (_ delayMs: Double, _ action: @escaping @Sendable () -> Void) -> Void

    public private(set) var parameters: [ParameterDefinition] = []

    private let context: JSContext
    private let send: SendHandler
    private let trace: TraceHandler
    private let schedule: Scheduler
    private var values: [Double] = []
    private var indexByName: [String: Int] = [:]
    private var dispatchFn: JSValue?
    private var parameterChangedFn: JSValue?
    private var idleFn: JSValue?
    private var warned: Set<String> = []

    private final class ExceptionBox: @unchecked Sendable {
        var last: String?
    }
    private let exceptionBox = ExceptionBox()

    public init(
        script: String,
        scriptName: String = "script.js",
        configParameters: [String: ParameterValue] = [:],
        send: @escaping SendHandler,
        trace: @escaping TraceHandler = { print($0) },
        schedule: @escaping Scheduler
    ) throws {
        guard let context = JSContext() else {
            throw MidimendError.script("could not create JavaScriptCore context")
        }
        self.context = context
        self.send = send
        self.trace = trace
        self.schedule = schedule

        let box = exceptionBox
        context.exceptionHandler = { _, exception in
            let message = exception?.toString() ?? "unknown"
            let line = exception.flatMap { $0.forProperty("line")?.toString() } ?? "?"
            box.last = message
            trace("[JS Exception] \(message) line:\(line)")
        }

        installNatives()
        try evaluateBootstrap()
        try evaluateUserScript(script, name: scriptName)
        readPluginParameters()
        resolveCallbacks()
        applyConfigParameters(configParameters)
        fireParameterChangedForAll()
        warnAboutTimingInfoIfNeeded()
        trace("Script evaluated successfully!")
    }

    // MARK: - Public entry points (call on the owning queue only)

    public func handleIncoming(_ event: MIDIEventBytes, port: Int = 1) {
        dispatchFn?.call(withArguments: [Int(event.status), Int(event.data1), Int(event.data2), port])
    }

    public func idleTick() {
        idleFn?.call(withArguments: [])
        // JSC registers its GC housekeeping timers on the run loop of the
        // VM-creating thread, and run loops never spin on a GCD worker — so
        // left alone, collection only happens synchronously when an
        // allocation threshold is hit, possibly mid-HandleMIDI. Collecting
        // here keeps the heap small enough that that rarely triggers.
        JSGarbageCollect(context.jsGlobalContextRef)
    }

    public func currentValue(named name: String) -> Double? {
        guard let index = indexByName[name] else { return nil }
        return values[index]
    }

    // MARK: - Bootstrap

    private func evaluateBootstrap() throws {
        let source = String(decoding: PackageResources.Bootstrap_js, as: UTF8.self)
        exceptionBox.last = nil
        context.evaluateScript(source, withSourceURL: URL(fileURLWithPath: "Bootstrap.js"))
        if let error = exceptionBox.last {
            throw MidimendError.script("bootstrap failed to evaluate: \(error)")
        }
    }

    private func evaluateUserScript(_ script: String, name: String) throws {
        exceptionBox.last = nil
        context.evaluateScript(script, withSourceURL: URL(fileURLWithPath: name))
        if let error = exceptionBox.last {
            throw MidimendError.script("Script failed to evaluate: \(error)")
        }
    }

    private func resolveCallbacks() {
        dispatchFn = context.objectForKeyedSubscript("_dispatchMIDIEvent")
        let resolve = context.objectForKeyedSubscript("_resolveUserCallback")
        func callback(_ name: String) -> JSValue? {
            guard let value = resolve?.call(withArguments: [name]), !value.isUndefined else { return nil }
            return value
        }
        parameterChangedFn = callback("ParameterChanged")
        idleFn = callback("Idle")
    }

    // MARK: - Natives exposed to JS

    private func installNatives() {
        let sendNow: @convention(block) (JSValue) -> Void = { [unowned self] event in
            guard let bytes = Self.eventBytes(from: event) else {
                self.trace("Error: send() called with a malformed MIDI event.")
                return
            }
            self.send(bytes)
        }
        setGlobal("SendMIDIEventNow", sendNow)

        let sendAfterMs: @convention(block) (JSValue, JSValue) -> Void = { [unowned self] event, ms in
            guard let bytes = Self.eventBytes(from: event) else {
                self.trace("Error: sendAfterMilliseconds() called with a malformed MIDI event.")
                return
            }
            let delay = max(0, ms.toDouble())
            let send = self.send
            self.schedule(delay) { send(bytes) }
        }
        setGlobal("SendMIDIEventAfterMilliseconds", sendAfterMs)

        // No transport in v0: beat-domain sends degrade to immediate sends.
        let sendAtBeat: @convention(block) (JSValue, JSValue) -> Void = { [unowned self] event, _ in
            self.warnOnce("sendAtBeat()/sendAfterBeats() need a transport, which v0 does not have; sending immediately.")
            guard let bytes = Self.eventBytes(from: event) else { return }
            self.send(bytes)
        }
        setGlobal("SendMIDIEventAtBeat", sendAtBeat)
        setGlobal("SendMIDIEventAfterBeats", sendAtBeat)

        let traceFn: @convention(block) (JSValue) -> Void = { [unowned self] value in
            guard !value.isUndefined else { return }
            self.trace(value.toString() ?? "undefined")
        }
        setGlobal("Trace", traceFn)

        let getParameter: @convention(block) (JSValue) -> JSValue = { [unowned self] key in
            guard let index = self.parameterIndex(for: key, function: "GetParameter") else {
                return JSValue(undefinedIn: self.context)
            }
            return JSValue(double: self.values[index], in: self.context)
        }
        setGlobal("GetParameter", getParameter)

        let setParameter: @convention(block) (JSValue, JSValue) -> Void = { [unowned self] key, value in
            guard let index = self.parameterIndex(for: key, function: "SetParameter") else { return }
            self.setValue(value.toDouble(), at: index)
        }
        setGlobal("SetParameter", setParameter)

        let getTimingInfo: @convention(block) () -> JSValue = { [unowned self] in
            self.warnOnce("GetTimingInfo() is not available: Midimend v0 has no transport.")
            return JSValue(undefinedIn: self.context)
        }
        setGlobal("GetTimingInfo", getTimingInfo)

        let updatePluginParameters: @convention(block) () -> Void = { [unowned self] in
            self.warnOnce("UpdatePluginParameters() has no effect (parameters come from the config file).")
        }
        setGlobal("UpdatePluginParameters", updatePluginParameters)

        let hostWarnOnce: @convention(block) (JSValue) -> Void = { [unowned self] message in
            self.warnOnce(message.toString() ?? "")
        }
        setGlobal("_HostWarnOnce", hostWarnOnce)
    }

    private func setGlobal(_ name: String, _ value: Any) {
        context.setObject(value, forKeyedSubscript: name as NSString)
    }

    private func warnOnce(_ message: String) {
        if warned.insert(message).inserted {
            trace("Warning: \(message)")
        }
    }

    // MARK: - Event extraction

    private static func eventBytes(from event: JSValue) -> MIDIEventBytes? {
        guard event.isObject else { return nil }
        let statusValue = event.forProperty("status")?.toInt32() ?? 0
        let type = UInt8(clamping: statusValue) & 0xF0
        guard (0x80...0xE0).contains(type) else { return nil }
        let channel = event.forProperty("channel")?.toInt32() ?? 1
        let channelNibble = UInt8(clamping: min(15, max(0, channel - 1)))
        return MIDIEventBytes(
            status: type | channelNibble,
            data1: dataByte(event.forProperty("data1")),
            data2: dataByte(event.forProperty("data2"))
        )
    }

    private static func dataByte(_ value: JSValue?) -> UInt8 {
        UInt8(clamping: min(127, max(0, value?.toInt32() ?? 0)))
    }

    // MARK: - Parameters

    private func readPluginParameters() {
        guard let resolved = context.objectForKeyedSubscript("_resolvePluginParameters")?.call(withArguments: []),
              !resolved.isUndefined,
              let list = resolved.toArray() else {
            return
        }
        for (position, element) in list.enumerated() {
            guard let dict = element as? [String: Any] else { continue }
            guard let name = dict["name"] as? String else {
                trace("PluginParameters[\(position)] is missing a name")
                continue
            }
            let valueStrings = dict["valueStrings"] as? [String] ?? []
            let type = dict["type"] as? String ?? "lin"
            var minValue = (dict["minValue"] as? NSNumber)?.doubleValue ?? 0
            var maxValue = (dict["maxValue"] as? NSNumber)?.doubleValue ?? 1
            if type == "menu" || !valueStrings.isEmpty {
                minValue = 0
                maxValue = Double(max(0, valueStrings.count - 1))
            }
            let defaultValue = clamp((dict["defaultValue"] as? NSNumber)?.doubleValue ?? 0,
                                     min: minValue, max: maxValue)
            let definition = ParameterDefinition(
                name: name, type: type, defaultValue: defaultValue,
                minValue: minValue, maxValue: maxValue, valueStrings: valueStrings
            )
            if indexByName[name] == nil {
                indexByName[name] = parameters.count
            }
            parameters.append(definition)
            values.append(defaultValue)
        }
    }

    private func applyConfigParameters(_ config: [String: ParameterValue]) {
        for (name, value) in config {
            guard let index = indexByName[name] else {
                trace("Warning: config parameter '\(name)' does not match any PluginParameters entry.")
                continue
            }
            let definition = parameters[index]
            let resolved: Double
            switch value {
            case .number(let number):
                resolved = number
            case .bool(let flag):
                resolved = flag ? 1 : 0
            case .string(let string):
                if let menuIndex = definition.valueStrings.firstIndex(of: string) {
                    resolved = Double(menuIndex)
                } else if let number = Double(string) {
                    resolved = number
                } else {
                    trace("Warning: config value '\(string)' for '\(name)' matches no valueStrings entry.")
                    continue
                }
            }
            values[index] = clamp(resolved, min: definition.minValue, max: definition.maxValue)
        }
    }

    /// ParameterChanged fires once per parameter after every (re)load, so
    /// scripts can initialize their state from the current values — the same
    /// behavior as loading a plug-in setting.
    private func fireParameterChangedForAll() {
        for index in parameters.indices {
            parameterChangedFn?.call(withArguments: [index, values[index]])
        }
    }

    private func setValue(_ value: Double, at index: Int) {
        let definition = parameters[index]
        values[index] = clamp(value, min: definition.minValue, max: definition.maxValue)
        parameterChangedFn?.call(withArguments: [index, values[index]])
    }

    private func parameterIndex(for key: JSValue, function: String) -> Int? {
        if key.isNumber {
            let index = Int(key.toInt32())
            guard parameters.indices.contains(index) else {
                trace("Error: \(function)() called with out-of-range index \(index).")
                return nil
            }
            return index
        }
        if key.isString, let name = key.toString() {
            guard let index = indexByName[name] else {
                trace("Error: \(function)() called with unknown parameter name '\(name)'.")
                return nil
            }
            return index
        }
        trace("Error: \(function)() called with an argument that is neither a string (the parameter name) nor a number (the parameter index).")
        return nil
    }

    private func warnAboutTimingInfoIfNeeded() {
        if let needs = context.objectForKeyedSubscript("_resolveNeedsTimingInfo")?.call(withArguments: []),
           needs.toBool() {
            warnOnce("NeedsTimingInfo is set, but Midimend v0 has no transport; GetTimingInfo() returns undefined and beatPos is always 0.")
        }
    }

    private func clamp(_ value: Double, min minValue: Double, max maxValue: Double) -> Double {
        guard minValue < maxValue else { return value }
        return min(maxValue, max(minValue, value))
    }
}
