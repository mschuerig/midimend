import XCTest
@testable import MidimendCore

final class ConfigDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    func testFullMIDISetup() throws {
        let config = try decode("""
        {
          "script": "s.js",
          "midi": {
            "inputs": [{ "hardware": "Minilab" }, { "virtual": "Midimend In" }],
            "outputs": [{ "virtual": "Midimend Out" }],
            "ignore": ["DAW"]
          }
        }
        """)
        XCTAssertEqual(config.midi.inputs, [
            EndpointSpec(hardware: "Minilab"),
            EndpointSpec(virtualName: "Midimend In"),
        ])
        XCTAssertEqual(config.midi.outputs, [EndpointSpec(virtualName: "Midimend Out")])
        XCTAssertEqual(config.midi.ignore, ["DAW"])
        XCTAssertNil(config.parameters)
    }

    func testOmittedInputsDecodeAsNil() throws {
        let config = try decode("""
        { "script": "s.js", "midi": { "outputs": [{ "virtual": "Out" }] } }
        """)
        XCTAssertNil(config.midi.inputs)
        XCTAssertNil(config.midi.ignore)
    }

    // MARK: - Feedback (DAW → paired virtual destination → controllers)

    func testFeedbackAllDecodesFromString() throws {
        let config = try decode("""
        { "script": "s.js", "midi": { "outputs": [{ "virtual": "Out" }], "feedback": "all" } }
        """)
        XCTAssertEqual(config.midi.feedback, .all)
    }

    func testFeedbackDeviceListDecodesAsEndpointSpecs() throws {
        let config = try decode("""
        {
          "script": "s.js",
          "midi": {
            "outputs": [{ "virtual": "Out" }],
            "feedback": [{ "hardware": "X-TOUCH" }, { "hardware": "Launchpad" }]
          }
        }
        """)
        XCTAssertEqual(config.midi.feedback, .devices([
            EndpointSpec(hardware: "X-TOUCH"),
            EndpointSpec(hardware: "Launchpad"),
        ]))
    }

    func testOmittedFeedbackDecodesAsNil() throws {
        let config = try decode("""
        { "script": "s.js", "midi": { "outputs": [{ "virtual": "Out" }] } }
        """)
        XCTAssertNil(config.midi.feedback)
    }

    func testFeedbackRejectsUnknownString() throws {
        XCTAssertThrowsError(try decode("""
        { "script": "s.js", "midi": { "outputs": [], "feedback": "everything" } }
        """))
    }

    /// The restart-to-apply note depends on MIDISetup equality noticing
    /// feedback changes.
    func testFeedbackParticipatesInMIDISetupEquality() {
        let without = MIDISetup(outputs: [])
        var with = MIDISetup(outputs: [])
        with.feedback = .all
        XCTAssertNotEqual(without, with)
    }

    func testParameterValueKinds() throws {
        let config = try decode("""
        {
          "script": "s.js",
          "midi": { "outputs": [] },
          "parameters": { "CC": 28, "Mode": "Auto", "Enabled": true }
        }
        """)
        XCTAssertEqual(config.parameters?["CC"], .number(28))
        XCTAssertEqual(config.parameters?["Mode"], .string("Auto"))
        XCTAssertEqual(config.parameters?["Enabled"], .bool(true))
    }

    // MARK: - keepAwake (opt-in display wake)

    func testKeepAwakeDecodesWhenPresent() throws {
        let config = try decode("""
        { "script": "s.js", "midi": { "outputs": [] }, "keepAwake": true }
        """)
        XCTAssertEqual(config.keepAwake, true)
    }

    func testKeepAwakeDefaultsToNilWhenOmitted() throws {
        let config = try decode("""
        { "script": "s.js", "midi": { "outputs": [] } }
        """)
        XCTAssertNil(config.keepAwake)
    }

    /// The well-known config home: visible in Finder, next to the user's
    /// scripts, in the folder musicians already know from Logic/MainStage
    /// (~/Music/Audio Music Apps).
    func testDefaultConfigLocation() {
        XCTAssertEqual(
            Config.defaultURL.path,
            (NSHomeDirectory() as NSString).appendingPathComponent("Music/Midimend/config.json")
        )
    }

    func testScriptURLResolution() {
        let configURL = URL(fileURLWithPath: "/etc/midimend/config.json")
        var config = Config(script: "s.js", midi: MIDISetup(outputs: []), parameters: nil)

        XCTAssertEqual(config.scriptURL(relativeTo: configURL).path, "/etc/midimend/s.js")

        config.script = "/abs/s.js"
        XCTAssertEqual(config.scriptURL(relativeTo: configURL).path, "/abs/s.js")

        config.script = "~/s.js"
        XCTAssertEqual(config.scriptURL(relativeTo: configURL).path,
                       (NSHomeDirectory() as NSString).appendingPathComponent("s.js"))
    }
}
