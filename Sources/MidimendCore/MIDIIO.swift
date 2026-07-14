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
    /// One per virtual output, same name: the port a DAW's parameter
    /// feedback (e.g. MainStage "Send Value to") is addressed to. MainStage
    /// pairs source and destination by name, so the shared name is what
    /// enables its feedback popup for our port.
    private var pairedDestinations: [MIDIEndpointRef] = []

    private let selection: EndpointSelection
    private let receive: ReceiveHandler
    private let log: @Sendable (String) -> Void

    private let stateLock = NSLock()
    private var hardwareDestinations: [MIDIEndpointRef] = []
    private var feedbackDestinations: [MIDIEndpointRef] = []
    private var connectedSourceIDs: Set<MIDIUniqueID> = []
    private var presentSourceNames: Set<String> = []
    private var presentDestinationNames: Set<String> = []
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

            guard selection.feedbackConfigured else { continue }
            var paired = MIDIEndpointRef()
            try check(MIDIDestinationCreateWithProtocol(client, name as CFString, ._1_0, &paired) { [weak self] eventList, _ in
                self?.handleFeedback(eventList)
            }, "MIDIDestinationCreate(feedback \(name))")
            assignStableUniqueID(paired, key: "feedback:\(name)")
            pairedDestinations.append(paired)
            log("Created feedback port for: \(name)")
        }

        // Seed the plug/unplug snapshot with what's already present so startup
        // doesn't report every pre-existing device as freshly "appeared".
        presentSourceNames = hardwareSourceNames()
        presentDestinationNames = hardwareDestinationNames()
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

    // MARK: - Feedback (paired destinations → controllers)

    /// Forwards everything a DAW sends to a paired destination, unmodified,
    /// to the feedback destinations — and only there. Sending to our own
    /// virtual sources would loop the DAW's feedback straight back into it
    /// as input.
    private func handleFeedback(_ eventList: UnsafePointer<MIDIEventList>) {
        stateLock.lock()
        let destinations = feedbackDestinations
        stateLock.unlock()
        for destination in destinations {
            MIDISendEventList(outputPort, destination, eventList)
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
        logEndpointChanges()
        connectMatchingSources()
        resolveHardwareDestinations()
        resolveFeedbackDestinations()
    }

    /// Destinations midimend itself owns — never "hardware", and in
    /// feedback-"all" mode a paired destination must not match itself
    /// (that would re-enter `handleFeedback` forever).
    private func isOwnDestination(_ endpoint: MIDIEndpointRef) -> Bool {
        virtualDestinations.contains(endpoint) || pairedDestinations.contains(endpoint)
    }

    /// Logs hardware endpoints that have appeared or disappeared since the last
    /// setup-change, so the log shows plug/unplug events even for devices that
    /// don't match the config — otherwise a keyboard that fails to connect is
    /// indistinguishable from one that was never seen.
    private func logEndpointChanges() {
        let sources = hardwareSourceNames()
        let destinations = hardwareDestinationNames()
        stateLock.lock()
        let messages = EndpointChanges.messages(
            previousSources: presentSourceNames, currentSources: sources,
            previousDestinations: presentDestinationNames, currentDestinations: destinations
        )
        presentSourceNames = sources
        presentDestinationNames = destinations
        stateLock.unlock()
        messages.forEach(log)
    }

    private func hardwareSourceNames() -> Set<String> {
        var names: Set<String> = []
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            guard source != 0, !virtualSources.contains(source),
                  let name = midiDisplayName(source) else { continue }
            names.insert(name)
        }
        return names
    }

    private func hardwareDestinationNames() -> Set<String> {
        var names: Set<String> = []
        for index in 0..<MIDIGetNumberOfDestinations() {
            let destination = MIDIGetDestination(index)
            guard destination != 0, !isOwnDestination(destination),
                  let name = midiDisplayName(destination) else { continue }
            names.insert(name)
        }
        return names
    }

    private func connectMatchingSources() {
        var present: [SourceSync.Present] = []
        var endpoints: [MIDIUniqueID: MIDIEndpointRef] = [:]
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            guard source != 0, !virtualSources.contains(source),
                  let name = midiDisplayName(source) else { continue }
            var uniqueID: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &uniqueID)
            var matched = false
            if case .connected = selection.input(name) { matched = true }
            present.append(SourceSync.Present(id: uniqueID, name: name, matched: matched))
            endpoints[uniqueID] = source
        }

        stateLock.lock()
        let plan = SourceSync.plan(present: present, connected: connectedSourceIDs)
        connectedSourceIDs = plan.retainedIDs
        stateLock.unlock()

        for source in plan.connect {
            guard let endpoint = endpoints[source.id] else { continue }
            let status = MIDIPortConnectSource(inputPort, endpoint, nil)
            if status == noErr {
                stateLock.lock()
                connectedSourceIDs.insert(source.id)
                stateLock.unlock()
                log("Connected input: \(source.name)")
            } else {
                log("warning: could not connect input \(source.name) (MIDIPortConnectSource: \(status))")
            }
        }
    }

    private func resolveHardwareDestinations() {
        var found: [MIDIEndpointRef] = []
        var names: [String] = []
        for index in 0..<MIDIGetNumberOfDestinations() {
            let destination = MIDIGetDestination(index)
            guard destination != 0, !isOwnDestination(destination),
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

    private func resolveFeedbackDestinations() {
        guard selection.feedbackConfigured else { return }
        var found: [MIDIEndpointRef] = []
        var names: [String] = []
        for index in 0..<MIDIGetNumberOfDestinations() {
            let destination = MIDIGetDestination(index)
            guard destination != 0, !isOwnDestination(destination),
                  let name = midiDisplayName(destination),
                  case .connected = selection.feedback(name) else { continue }
            found.append(destination)
            names.append(name)
        }
        stateLock.lock()
        let changed = feedbackDestinations != found
        feedbackDestinations = found
        stateLock.unlock()
        if changed {
            log("Feedback outputs: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
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
            guard destination != 0, !isOwnDestination(destination) else { return nil }
            return midiDisplayName(destination)
        }
        warnUnmatched(selection.unmatchedInputPatterns(among: sourceNames),
                      present: sourceNames, kind: "input")
        warnUnmatched(selection.unmatchedOutputPatterns(among: destinationNames),
                      present: destinationNames, kind: "output")
        warnUnmatched(selection.unmatchedFeedbackPatterns(among: destinationNames),
                      present: destinationNames, kind: "feedback destination")
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
