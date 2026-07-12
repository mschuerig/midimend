import Foundation
import CoreMIDI

/// CoreMIDI plumbing: virtual in/out ports plus name-matched hardware
/// endpoints, speaking MIDI 1.0 over the UMP (MIDIEventList) APIs.
///
/// Incoming channel-voice messages are delivered to `receive` on a
/// CoreMIDI-owned thread; the caller is responsible for hopping onto its own
/// processing queue. System real-time/common messages (clock, start/stop,
/// song position) are passed straight through to the outputs.
///
/// `receive` gets the packet's driver-receipt host time (`mach_absolute_time`
/// units) so the caller can measure its own added latency.
public final class MIDIIO: @unchecked Sendable {
    public typealias ReceiveHandler = @Sendable (MIDIEventBytes, Int, UInt64) -> Void

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var virtualDestinations: [MIDIEndpointRef] = []
    private var virtualSources: [MIDIEndpointRef] = []

    private let selection: EndpointSelection
    private let receive: ReceiveHandler
    private let log: @Sendable (String) -> Void

    private let stateLock = NSLock()
    private var hardwareDestinations: [MIDIEndpointRef] = []
    private var connectedSourceIDs: Set<MIDIUniqueID> = []
    private let adminQueue = DispatchQueue(label: "midimend.midi-admin")

    public init(
        setup: MIDISetup,
        receive: @escaping ReceiveHandler,
        log: @escaping @Sendable (String) -> Void = { print($0) }
    ) throws {
        self.receive = receive
        self.log = log
        self.selection = EndpointSelection(setup: setup)

        try check(MIDIClientCreateWithBlock("Midimend" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged, let self {
                self.adminQueue.async { self.refreshHardwareEndpoints() }
            }
        }, "MIDIClientCreate")

        try check(MIDIInputPortCreateWithProtocol(client, "input" as CFString, ._1_0, &inputPort) { [weak self] eventList, _ in
            self?.handle(eventList)
        }, "MIDIInputPortCreate")

        try check(MIDIOutputPortCreate(client, "output" as CFString, &outputPort), "MIDIOutputPortCreate")

        for spec in setup.inputs ?? [] {
            guard let name = spec.virtualName else { continue }
            var endpoint = MIDIEndpointRef()
            try check(MIDIDestinationCreateWithProtocol(client, name as CFString, ._1_0, &endpoint) { [weak self] eventList, _ in
                self?.handle(eventList)
            }, "MIDIDestinationCreate(\(name))")
            assignStableUniqueID(endpoint, key: "destination:\(name)")
            virtualDestinations.append(endpoint)
            log("Created virtual input: \(name)")
        }

        for spec in setup.outputs {
            guard let name = spec.virtualName else { continue }
            var endpoint = MIDIEndpointRef()
            try check(MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &endpoint),
                      "MIDISourceCreate(\(name))")
            assignStableUniqueID(endpoint, key: "source:\(name)")
            virtualSources.append(endpoint)
            log("Created virtual output: \(name)")
        }

        refreshHardwareEndpoints()
        reportMissingHardware()
    }

    deinit {
        if client != 0 { MIDIClientDispose(client) }
    }

    // MARK: - Sending

    public func send(_ event: MIDIEventBytes) {
        sendWords([MIDI1UMP.word(for: event)])
    }

    private func sendWords(_ words: [UInt32]) {
        var eventList = MIDIEventList()
        var packet = MIDIEventListInit(&eventList, ._1_0)
        words.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            packet = MIDIEventListAdd(&eventList, MemoryLayout<MIDIEventList>.size,
                                      packet, 0, buffer.count, base)
        }
        for source in virtualSources {
            MIDIReceivedEventList(source, &eventList)
        }
        stateLock.lock()
        let destinations = hardwareDestinations
        stateLock.unlock()
        for destination in destinations {
            MIDISendEventList(outputPort, destination, &eventList)
        }
    }

    // MARK: - Receiving

    private func handle(_ eventList: UnsafePointer<MIDIEventList>) {
        for packetPointer in eventList.unsafeSequence() {
            // A zero timestamp means "now" (typical for apps sending to our
            // virtual input); substitute the actual receipt time.
            var timestamp = packetPointer.pointee.timeStamp
            if timestamp == 0 { timestamp = mach_absolute_time() }
            let wordCount = Int(packetPointer.pointee.wordCount)
            let words = withUnsafeBytes(of: packetPointer.pointee.words) { raw in
                Array(raw.bindMemory(to: UInt32.self).prefix(wordCount))
            }
            for action in MIDI1UMP.parse(words) {
                switch action {
                case .channelVoice(let bytes):
                    receive(bytes, 1, timestamp)
                case .passThrough(let word):
                    sendWords([word])
                }
            }
        }
    }

    // MARK: - Hardware endpoints

    private func refreshHardwareEndpoints() {
        connectMatchingSources()
        resolveHardwareDestinations()
    }

    private func connectMatchingSources() {
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            guard source != 0, !virtualSources.contains(source),
                  let name = midiDisplayName(source),
                  case .connected = selection.input(name) else { continue }
            var uniqueID: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &uniqueID)
            stateLock.lock()
            let alreadyConnected = connectedSourceIDs.contains(uniqueID)
            stateLock.unlock()
            guard !alreadyConnected else { continue }
            if MIDIPortConnectSource(inputPort, source, nil) == noErr {
                stateLock.lock()
                connectedSourceIDs.insert(uniqueID)
                stateLock.unlock()
                log("Connected input: \(name)")
            }
        }
    }

    private func resolveHardwareDestinations() {
        var found: [MIDIEndpointRef] = []
        var names: [String] = []
        for index in 0..<MIDIGetNumberOfDestinations() {
            let destination = MIDIGetDestination(index)
            guard destination != 0, !virtualDestinations.contains(destination),
                  let name = midiDisplayName(destination),
                  case .connected = selection.output(name) else { continue }
            found.append(destination)
            names.append(name)
        }
        stateLock.lock()
        let changed = hardwareDestinations != found
        hardwareDestinations = found
        stateLock.unlock()
        if changed {
            log("Connected outputs: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
        }
    }

    /// Startup diagnosis: a configured device that isn't present gets a
    /// warning listing the devices that are. Not an error — the setup-change
    /// notification connects the device if it appears later.
    private func reportMissingHardware() {
        let sourceNames = (0..<MIDIGetNumberOfSources()).compactMap { index -> String? in
            let source = MIDIGetSource(index)
            guard source != 0, !virtualSources.contains(source) else { return nil }
            return midiDisplayName(source)
        }
        let destinationNames = (0..<MIDIGetNumberOfDestinations()).compactMap { index -> String? in
            let destination = MIDIGetDestination(index)
            guard destination != 0, !virtualDestinations.contains(destination) else { return nil }
            return midiDisplayName(destination)
        }
        warnUnmatched(selection.unmatchedInputPatterns(among: sourceNames),
                      present: sourceNames, kind: "input")
        warnUnmatched(selection.unmatchedOutputPatterns(among: destinationNames),
                      present: destinationNames, kind: "output")
    }

    private func warnUnmatched(_ missing: [String], present: [String], kind: String) {
        guard !missing.isEmpty else { return }
        let quoted = missing.map { "\"\($0)\"" }.joined(separator: ", ")
        let available = present.isEmpty ? "none" : present.joined(separator: ", ")
        log("warning: no MIDI \(kind) matching \(quoted) — connecting automatically if it appears; present \(kind)s: \(available)")
    }

    /// A stable unique ID lets other apps' saved connections re-bind to our
    /// virtual ports across restarts. Collisions just fall back to the random
    /// ID CoreMIDI already assigned.
    private func assignStableUniqueID(_ endpoint: MIDIEndpointRef, key: String) {
        var hash: UInt32 = 2166136261
        for byte in "midimend:\(key)".utf8 {
            hash = (hash ^ UInt32(byte)) &* 16777619
        }
        var uniqueID = MIDIUniqueID(bitPattern: hash)
        if uniqueID == 0 { uniqueID = 1 }
        MIDIObjectSetIntegerProperty(endpoint, kMIDIPropertyUniqueID, uniqueID)
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else {
            throw MidimendError.midi("\(what) failed", status)
        }
    }
}
