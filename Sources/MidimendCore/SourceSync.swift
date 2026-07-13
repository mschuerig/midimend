import CoreMIDI

/// Decides, on each setup-change, which present sources MIDIIO should connect
/// and which remembered connections to forget. Pure so the dedup/prune rules
/// are testable without CoreMIDI; MIDIIO enumerates endpoints, asks for a
/// plan, and executes it.
enum SourceSync {
    struct Present: Equatable {
        let id: MIDIUniqueID
        let name: String
        /// Whether the config's selection rules connect this source.
        let matched: Bool
    }

    struct Plan: Equatable {
        /// Matched sources not yet connected — connect these.
        let connect: [Present]
        /// Remembered connections whose source is still present — keep these;
        /// the rest belong to vanished devices and must be forgotten so a
        /// replug (CoreMIDI may reuse the unique ID) reconnects instead of
        /// looking already-connected against a severed connection.
        let retainedIDs: Set<MIDIUniqueID>
    }

    static func plan(present: [Present], connected: Set<MIDIUniqueID>) -> Plan {
        Plan(
            connect: present.filter { $0.matched && !connected.contains($0.id) },
            retainedIDs: connected.intersection(present.map(\.id))
        )
    }
}
