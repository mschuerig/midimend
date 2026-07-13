import Foundation
import Midimend

// Under launchd/brew services stdout is a file: without this, messages sit
// in stdio's full buffer and are lost on SIGTERM — the service log must
// show connects/reloads as they happen.
setlinebuf(stdout)

let arguments = Array(CommandLine.arguments.dropFirst())

/// Bumped per release; the release workflow refuses tags that don't match.
let midimendVersion = "0.2.1"

func printUsage() {
    print("""
    usage: midimend [config.json]
           midimend --measure [config.json]
           midimend --list-devices [config.json]
           midimend --init <script.js>

    Mends MIDI between CoreMIDI ports by running a JavaScript processing
    script per event. See README.md for the config file format and script API.

    Without arguments, runs the config at \(Config.defaultURL.path).

    --measure       run normally, printing midimend's added latency every
                    10 seconds (percentiles from MIDI driver receipt to
                    script entry and to processing done)
    --list-devices  print the MIDI devices currently present; given a config,
                    also show which of them its "hardware" entries match
    --init          print a config skeleton for the script, with its
                    PluginParameters defaults filled in (redirect to a file:
                    midimend --init script.js > config.json)
    --version       print the version
    """)
}

func fail(_ error: Error) -> Never {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

func listDevices(configPath: String?) throws {
    var selection: EndpointSelection?
    if let configPath {
        let setup = try Config.load(from: URL(fileURLWithPath: configPath).standardizedFileURL).midi
        selection = EndpointSelection(setup: setup)
    }
    let devices = DeviceList.current()
    deviceLines(title: "MIDI inputs (sources)", names: devices.sources,
                verdict: selection.map { s in { s.input($0) } },
                missing: selection?.unmatchedInputPatterns(among: devices.sources) ?? [])
        .forEach { print($0) }
    print("")
    deviceLines(title: "MIDI outputs (destinations)", names: devices.destinations,
                verdict: selection.map { s in { s.output($0) } },
                missing: selection?.unmatchedOutputPatterns(among: devices.destinations) ?? [])
        .forEach { print($0) }
}

func initTemplate(scriptPath: String) throws {
    let url = URL(fileURLWithPath: scriptPath).standardizedFileURL
    let source: String
    do {
        source = try String(contentsOf: url, encoding: .utf8)
    } catch {
        throw MidimendError.script("cannot read script \(url.path): \(error.localizedDescription)")
    }
    // Warnings and Trace() output go to stderr so stdout stays clean JSON.
    let engine = try ScriptEngine(
        script: source,
        scriptName: url.lastPathComponent,
        send: { _ in },
        trace: { message in FileHandle.standardError.write(Data((message + "\n").utf8)) },
        schedule: { _, _ in }
    )
    print(ConfigTemplate.render(scriptPath: scriptPath, parameters: engine.parameters))
}

func defaultConfigPath() -> String {
    let defaultURL = Config.defaultURL
    guard FileManager.default.fileExists(atPath: defaultURL.path) else {
        FileHandle.standardError.write(Data("""
        error: no config found at \(defaultURL.path)

        Create one there — a skeleton to start from:
            midimend --init your-script.js > \(defaultURL.path)
        — or pass a config file directly: midimend <config.json>

        """.utf8))
        exit(1)
    }
    return defaultURL.path
}

let configPath: String
let measure: Bool

switch CLICommand.parse(arguments) {
case .run(let path, let measureFlag):
    configPath = path ?? defaultConfigPath()
    measure = measureFlag
case .listDevices(let path):
    do {
        try listDevices(configPath: path)
    } catch {
        fail(error)
    }
    exit(0)
case .initTemplate(let scriptPath):
    do {
        try initTemplate(scriptPath: scriptPath)
    } catch {
        fail(error)
    }
    exit(0)
case .version:
    print("midimend \(midimendVersion)")
    exit(0)
case .help:
    printUsage()
    exit(0)
case .usageError:
    printUsage()
    exit(1)
}

let engine: Engine
do {
    engine = try Engine(configPath: configPath, measure: measure)
    try engine.start()
    print("midimend running — Ctrl-C to quit")
} catch {
    fail(error)
}

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    print("")
    exit(0)
}
sigint.resume()

// Run the main run loop rather than dispatchMain(): CoreMIDI delivers the
// client's setup-change notifications (hot-plug of devices) only while the run
// loop of the thread that created the client — the main thread — is running.
// dispatchMain() services the main dispatch queue but runs no CFRunLoop, so
// hot-plugged devices would never connect. The SIGINT source above still fires
// because the running run loop drains the main dispatch queue.
withExtendedLifetime(engine) {
    CFRunLoopRun()
}
