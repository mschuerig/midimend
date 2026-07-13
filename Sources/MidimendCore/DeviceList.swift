import CoreMIDI

/// Display name of a CoreMIDI object — the name shown in Audio MIDI Setup,
/// including user renames.
func midiDisplayName(_ object: MIDIObjectRef) -> String? {
    var unmanaged: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &unmanaged) == noErr,
          let value = unmanaged?.takeRetainedValue() else { return nil }
    return value as String
}

/// The rule used to match `hardware` endpoint specs in the config:
/// case-insensitive substring.
public func midiNameMatches(_ name: String, pattern: String) -> Bool {
    name.localizedCaseInsensitiveContains(pattern)
}

/// Snapshot of the MIDI endpoints currently present, by display name.
public struct DeviceList: Sendable {
    public var sources: [String]
    public var destinations: [String]

    /// Enumerates the system's current endpoints. Creates (and disposes) a
    /// temporary CoreMIDI client — without one the endpoint list can be empty.
    public static func current() -> DeviceList {
        var client = MIDIClientRef()
        MIDIClientCreateWithBlock("Midimend" as CFString, &client, nil)
        defer { if client != 0 { MIDIClientDispose(client) } }

        var sources: [String] = []
        for index in 0..<MIDIGetNumberOfSources() {
            let endpoint = MIDIGetSource(index)
            if endpoint != 0, let name = midiDisplayName(endpoint) {
                sources.append(name)
            }
        }
        var destinations: [String] = []
        for index in 0..<MIDIGetNumberOfDestinations() {
            let endpoint = MIDIGetDestination(index)
            if endpoint != 0, let name = midiDisplayName(endpoint) {
                destinations.append(name)
            }
        }
        return DeviceList(sources: sources, destinations: destinations)
    }
}
