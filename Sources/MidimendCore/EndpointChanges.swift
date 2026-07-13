/// Turns a before/after snapshot of present hardware-endpoint names into
/// plug/unplug log lines. Pure so it can be tested without CoreMIDI; MIDIIO
/// feeds it the names it enumerates on each setup-change notification.
///
/// These fire regardless of whether a device matches the config, so the log
/// shows a keyboard being plugged in even when nothing connects — the missing
/// signal when a device silently fails to hook up.
enum EndpointChanges {
    static func messages(
        previousSources: Set<String>, currentSources: Set<String>,
        previousDestinations: Set<String>, currentDestinations: Set<String>
    ) -> [String] {
        var lines: [String] = []
        for name in currentSources.subtracting(previousSources).sorted() {
            lines.append("MIDI input appeared: \(name)")
        }
        for name in previousSources.subtracting(currentSources).sorted() {
            lines.append("MIDI input disappeared: \(name)")
        }
        for name in currentDestinations.subtracting(previousDestinations).sorted() {
            lines.append("MIDI output appeared: \(name)")
        }
        for name in previousDestinations.subtracting(currentDestinations).sorted() {
            lines.append("MIDI output disappeared: \(name)")
        }
        return lines
    }
}
