import XCTest
@testable import Midimend

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
