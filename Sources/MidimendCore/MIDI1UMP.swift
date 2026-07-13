/// MIDI 1.0 words in the Universal MIDI Packet framing that CoreMIDI's
/// MIDIEventList API speaks: one word per channel-voice message —
/// type nibble 0x2, group nibble, status byte, two 7-bit data bytes.
/// Pure; MIDIIO delegates its packet parsing and event encoding here.
public enum MIDI1UMP {
    public enum Action: Equatable, Sendable {
        case channelVoice(MIDIEventBytes)
        /// System real-time/common word, forwarded to the outputs verbatim.
        case passThrough(UInt32)
    }

    public static func parse(_ words: [UInt32]) -> [Action] {
        var actions: [Action] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            let messageType = UInt8(word >> 28)
            switch messageType {
            case 0x2: // MIDI 1.0 channel voice
                actions.append(.channelVoice(MIDIEventBytes(
                    status: UInt8((word >> 16) & 0xFF),
                    data1: UInt8((word >> 8) & 0x7F),
                    data2: UInt8(word & 0x7F)
                )))
                index += 1
            case 0x1: // system real-time / common
                actions.append(.passThrough(word))
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
        return actions
    }

    public static func word(for event: MIDIEventBytes) -> UInt32 {
        (0x2 << 28)
            | (UInt32(event.status) << 16)
            | (UInt32(event.data1) << 8)
            | UInt32(event.data2)
    }
}
