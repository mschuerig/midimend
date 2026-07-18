import XCTest
@testable import MidimendCore

final class ConfigTemplateTests: XCTestCase {

    private func definition(
        name: String,
        type: String = "lin",
        defaultValue: Double = 0,
        minValue: Double = 0,
        maxValue: Double = 127,
        valueStrings: [String] = []
    ) -> ParameterDefinition {
        ParameterDefinition(name: name, type: type, defaultValue: defaultValue,
                            minValue: minValue, maxValue: maxValue, valueStrings: valueStrings)
    }

    private func decode(_ rendered: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(rendered.utf8))
    }

    func testRendersDecodableConfigWithScriptPath() throws {
        let rendered = ConfigTemplate.render(scriptPath: "myscript.js", parameters: [])
        let config = try decode(rendered)
        XCTAssertEqual(config.script, "myscript.js")
        XCTAssertFalse(config.midi.outputs.isEmpty, "skeleton should propose a virtual output")
    }

    /// Plain "Midimend", not "Midimend Out": the port is a name-paired
    /// source/destination duo since parameter feedback, so a direction
    /// suffix would be wrong for one of the two.
    func testVirtualOutputIsNamedPlainMidimend() throws {
        let rendered = ConfigTemplate.render(scriptPath: "s.js", parameters: [])
        XCTAssertEqual(try decode(rendered).midi.outputs,
                       [EndpointSpec(virtualName: "Midimend")])
    }

    /// The generated default is feedback-on and *explicit*: the behavior must
    /// be readable in the config file, never implicit.
    func testSkeletonEmitsExplicitFeedbackAll() throws {
        let rendered = ConfigTemplate.render(scriptPath: "s.js", parameters: [])
        XCTAssertEqual(try decode(rendered).midi.feedback, .all)
        XCTAssertTrue(rendered.contains("\"feedback\": \"all\""))
    }

    /// The keep-awake opt-in is rendered explicitly and off, so it is
    /// discoverable in the file yet changes nothing until the user flips it.
    func testSkeletonEmitsExplicitKeepAwakeOff() throws {
        let rendered = ConfigTemplate.render(scriptPath: "s.js", parameters: [])
        XCTAssertEqual(try decode(rendered).keepAwake, false)
        XCTAssertTrue(rendered.contains("\"keepAwake\": false"))
    }

    /// keepAwake must render as valid JSON both with and without a trailing
    /// parameters section (comma placement).
    func testKeepAwakeRendersValidJSONWithParameters() throws {
        let rendered = ConfigTemplate.render(scriptPath: "s.js", parameters: [
            definition(name: "Source CC", defaultValue: 16),
        ])
        let config = try decode(rendered)
        XCTAssertEqual(config.keepAwake, false)
        XCTAssertEqual(config.parameters?["Source CC"], .number(16))
    }

    func testSliderBecomesNumber() throws {
        let rendered = ConfigTemplate.render(scriptPath: "s.js", parameters: [
            definition(name: "Source CC", defaultValue: 16),
        ])
        let config = try decode(rendered)
        XCTAssertEqual(config.parameters?["Source CC"], .number(16))
        XCTAssertTrue(rendered.contains("\"Source CC\": 16"), "integers should render without a decimal point")
    }

    func testNonIntegerDefaultKeepsFraction() throws {
        let rendered = ConfigTemplate.render(scriptPath: "s.js", parameters: [
            definition(name: "Gain", defaultValue: 0.5, maxValue: 1),
        ])
        XCTAssertEqual(try decode(rendered).parameters?["Gain"], .number(0.5))
    }

    func testMenuBecomesValueString() throws {
        let rendered = ConfigTemplate.render(scriptPath: "s.js", parameters: [
            definition(name: "Mode", type: "menu", defaultValue: 1, maxValue: 2,
                       valueStrings: ["Off", "Auto", "On"]),
        ])
        XCTAssertEqual(try decode(rendered).parameters?["Mode"], .string("Auto"))
    }

    func testCheckboxBecomesBool() throws {
        let rendered = ConfigTemplate.render(scriptPath: "s.js", parameters: [
            definition(name: "Enabled", type: "checkbox", defaultValue: 1, maxValue: 1),
            definition(name: "Muted", type: "checkbox", defaultValue: 0, maxValue: 1),
        ])
        let config = try decode(rendered)
        XCTAssertEqual(config.parameters?["Enabled"], .bool(true))
        XCTAssertEqual(config.parameters?["Muted"], .bool(false))
    }

    func testMomentaryAndTextAreSkipped() throws {
        let rendered = ConfigTemplate.render(scriptPath: "s.js", parameters: [
            definition(name: "Panic", type: "momentary"),
            definition(name: "A Label", type: "text"),
            definition(name: "Source CC", defaultValue: 16),
        ])
        let config = try decode(rendered)
        XCTAssertNil(config.parameters?["Panic"])
        XCTAssertNil(config.parameters?["A Label"])
        XCTAssertEqual(config.parameters?["Source CC"], .number(16))
    }

    func testNoConfigurableParametersOmitsSection() throws {
        let rendered = ConfigTemplate.render(scriptPath: "s.js", parameters: [
            definition(name: "A Label", type: "text"),
        ])
        XCTAssertNil(try decode(rendered).parameters)
        XCTAssertFalse(rendered.contains("\"parameters\""))
    }

    func testParametersKeepScriptOrder() throws {
        let rendered = ConfigTemplate.render(scriptPath: "s.js", parameters: [
            definition(name: "Zulu", defaultValue: 1),
            definition(name: "Alpha", defaultValue: 2),
        ])
        let zulu = try XCTUnwrap(rendered.range(of: "Zulu"))
        let alpha = try XCTUnwrap(rendered.range(of: "Alpha"))
        XCTAssertLessThan(zulu.lowerBound, alpha.lowerBound)
    }

    func testEscapesQuotesAndBackslashes() throws {
        let rendered = ConfigTemplate.render(scriptPath: #"we\ird".js"#, parameters: [
            definition(name: #"CC "fine""#, defaultValue: 3),
        ])
        let config = try decode(rendered)
        XCTAssertEqual(config.script, #"we\ird".js"#)
        XCTAssertEqual(config.parameters?[#"CC "fine""#], .number(3))
    }

    /// End to end: PluginParameters from a real script through the engine.
    func testTemplateFromEvaluatedScript() throws {
        let script = """
        var PluginParameters = [
            { name: "Source CC", type: "lin", minValue: 0, maxValue: 127,
              numberOfSteps: 127, defaultValue: 28 },
            { name: "Mode", type: "menu", valueStrings: ["Off", "Auto"], defaultValue: 1 },
        ];
        """
        let engine = try ScriptEngine(script: script, send: { _ in },
                                      trace: { _ in }, schedule: { _, _ in })
        let rendered = ConfigTemplate.render(scriptPath: "s.js", parameters: engine.parameters)
        let config = try decode(rendered)
        XCTAssertEqual(config.parameters?["Source CC"], .number(28))
        XCTAssertEqual(config.parameters?["Mode"], .string("Auto"))
    }
}
