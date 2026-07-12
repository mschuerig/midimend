import XCTest
@testable import Midimend

/// The MIDI 1.0 UMP word codec: what MIDIIO receives from and hands to
/// CoreMIDI's MIDIEventList API. Word layout (one word per channel-voice
/// message): type nibble 0x2, group, status byte, two 7-bit data bytes.
final class MIDI1UMPTests: XCTestCase {

    // MARK: - Decoding

    func testChannelVoiceWordDecodes() {
        XCTAssertEqual(MIDI1UMP.parse([0x2090_3C40]), [
            .channelVoice(MIDIEventBytes(status: 0x90, data1: 0x3C, data2: 0x40)),
        ])
    }

    func testDataBytesAreMaskedTo7Bits() {
        // High bits in the data byte positions must not leak through.
        XCTAssertEqual(MIDI1UMP.parse([0x2090_FFFF]), [
            .channelVoice(MIDIEventBytes(status: 0x90, data1: 0x7F, data2: 0x7F)),
        ])
    }

    func testGroupNibbleIsIrrelevantToDecoding() {
        XCTAssertEqual(MIDI1UMP.parse([0x2F90_3C40]), [
            .channelVoice(MIDIEventBytes(status: 0x90, data1: 0x3C, data2: 0x40)),
        ])
    }

    func testSystemRealtimePassesThroughVerbatim() {
        XCTAssertEqual(MIDI1UMP.parse([0x10F8_0000]), [.passThrough(0x10F8_0000)])
    }

    func testUtilityWordProducesNothing() {
        XCTAssertEqual(MIDI1UMP.parse([0x0000_0000]), [])
    }

    // MARK: - Multi-word packets keep the stream aligned

    func testSysex7ConsumesTwoWords() {
        // The second sysex word looks like a channel-voice word (0x2…) but
        // is payload — it must be skipped, and parsing resume after it.
        XCTAssertEqual(MIDI1UMP.parse([0x3015_2233, 0x2090_3C40, 0x2080_3C00]), [
            .channelVoice(MIDIEventBytes(status: 0x80, data1: 0x3C, data2: 0x00)),
        ])
    }

    func testMIDI2ChannelVoiceConsumesTwoWords() {
        XCTAssertEqual(MIDI1UMP.parse([0x4090_3C00, 0xFFFF_FFFF, 0x10F8_0000]), [
            .passThrough(0x10F8_0000),
        ])
    }

    func testData128ConsumesFourWords() {
        let payload: [UInt32] = [0x5000_0000, 0x2090_3C40, 0x2090_3C40, 0x2090_3C40]
        XCTAssertEqual(MIDI1UMP.parse(payload + [0x2090_3C40]), [
            .channelVoice(MIDIEventBytes(status: 0x90, data1: 0x3C, data2: 0x40)),
        ])
    }

    func testUnknownTypeSkipsOneWord() {
        XCTAssertEqual(MIDI1UMP.parse([0xF000_0000, 0x2090_3C40]), [
            .channelVoice(MIDIEventBytes(status: 0x90, data1: 0x3C, data2: 0x40)),
        ])
    }

    func testTruncatedMultiWordPacketDoesNotCrashOrMisparse() {
        XCTAssertEqual(MIDI1UMP.parse([0x3015_2233]), [])
    }

    func testMixedStreamPreservesOrder() {
        let actions = MIDI1UMP.parse([0x2090_3C40, 0x10F8_0000, 0x2080_3C00])
        XCTAssertEqual(actions, [
            .channelVoice(MIDIEventBytes(status: 0x90, data1: 0x3C, data2: 0x40)),
            .passThrough(0x10F8_0000),
            .channelVoice(MIDIEventBytes(status: 0x80, data1: 0x3C, data2: 0x00)),
        ])
    }

    // MARK: - Encoding

    func testEncodesChannelVoiceWord() {
        let word = MIDI1UMP.word(for: MIDIEventBytes(status: 0x90, data1: 0x3C, data2: 0x40))
        XCTAssertEqual(word, 0x2090_3C40)
    }

    func testEncodeDecodeRoundTrip() {
        let event = MIDIEventBytes(status: 0xB2, data1: 0x10, data2: 0x7F)
        XCTAssertEqual(MIDI1UMP.parse([MIDI1UMP.word(for: event)]), [.channelVoice(event)])
    }
}
