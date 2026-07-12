import Foundation
import CoreMIDI

/// CoreMIDI plumbing: virtual in/out ports plus name-matched hardware
/// endpoints, speaking MIDI 1.0 over the UMP (MIDIEventList) APIs.
///
/// Incoming channel-voice messages are delivered to `receive` on a
/// CoreMIDI-owned thread; the caller is responsible for hopping onto its own
/// processing queue. System real-time/common messages (clock, start/stop,
/// song position) are passed straight through to the outputs.
public final class MIDIIO: @unchecked Sendable {
    public typealias ReceiveHandler = @Sendable (MIDIEventBytes, Int) -> Void

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var virtualDestinations: [MIDIEndpointRef] = []
    private var virtualSources: [MIDIEndpointRef] = []

    private let hardwareInputPatterns: [String]
    private let hardwareOutputPatterns: [String]
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
        self.hardwareInputPatterns = setup.inputs.compactMap(\.hardware)
        self.hardwareOutputPatterns = setup.outputs.compactMap(\.hardware)

        try check(MIDIClientCreateWithBlock("Midimend" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged, let self {
                self.adminQueue.async { self.refreshHardwareEndpoints() }
            }
        }, "MIDIClientCreate")

        try check(MIDIInputPortCreateWithProtocol(client, "input" as CFString, ._1_0, &inputPort) { [weak self] eventList, _ in
            self?.handle(eventList)
        }, "MIDIInputPortCreate")

        try check(MIDIOutputPortCreate(client, "output" as CFString, &outputPort), "MIDIOutputPortCreate")

        for spec in setup.inputs {
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
    }

    deinit {
        if client != 0 { MIDIClientDispose(client) }
    }

    // MARK: - Sending

    public func send(_ event: MIDIEventBytes) {
        let word: UInt32 = (0x2 << 28)
            | (UInt32(event.status) << 16)
            | (UInt32(event.data1) << 8)
            | UInt32(event.data2)
        sendWords([word])
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
            let wordCount = Int(packetPointer.pointee.wordCount)
            withUnsafeBytes(of: packetPointer.pointee.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                var index = 0
                while index < min(wordCount, words.count) {
                    let word = words[index]
                    let messageType = UInt8(word >> 28)
                    switch messageType {
                    case 0x2: // MIDI 1.0 channel voice
                        let status = UInt8((word >> 16) & 0xFF)
                        let data1 = UInt8((word >> 8) & 0x7F)
                        let data2 = UInt8(word & 0x7F)
                        receive(MIDIEventBytes(status: status, data1: data1, data2: data2), 1)
                        index += 1
                    case 0x1: // system real-time / common: pass through untouched
                        sendWords([word])
                        index += 1
                    case 0x0: // utility (NOOP, jitter reduction)
                        index += 1
                    case 0x3, 0x4: // sysex7 / MIDI 2.0 channel voice
                        index += 2
                    case 0x5: // data 128
                        index += 4
                    default:
                        index += 1
                    }
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
        guard !hardwareInputPatterns.isEmpty else { return }
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            guard source != 0, !virtualSources.contains(source),
                  let name = displayName(source),
                  matches(name, patterns: hardwareInputPatterns) else { continue }
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
        guard !hardwareOutputPatterns.isEmpty else { return }
        var found: [MIDIEndpointRef] = []
        var names: [String] = []
        for index in 0..<MIDIGetNumberOfDestinations() {
            let destination = MIDIGetDestination(index)
            guard destination != 0, !virtualDestinations.contains(destination),
                  let name = displayName(destination),
                  matches(name, patterns: hardwareOutputPatterns) else { continue }
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

    private func matches(_ name: String, patterns: [String]) -> Bool {
        patterns.contains { name.localizedCaseInsensitiveContains($0) }
    }

    private func displayName(_ object: MIDIObjectRef) -> String? {
        var unmanaged: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &unmanaged) == noErr,
              let value = unmanaged?.takeRetainedValue() else { return nil }
        return value as String
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
