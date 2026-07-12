import Foundation
import Midimend

let arguments = Array(CommandLine.arguments.dropFirst())

func printUsage() {
    print("""
    usage: midimend <config.json>
           midimend --list-devices [config.json]
           midimend --init <script.js>

    Mends MIDI between CoreMIDI ports by running a JavaScript processing
    script per event. See README.md for the config file format and script API.

    --list-devices  print the MIDI devices currently present; given a config,
                    also show which of them its "hardware" entries match
    --init          print a config skeleton for the script, with its
                    PluginParameters defaults filled in (redirect to a file:
                    midimend --init script.js > config.json)
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
    printDevices("MIDI inputs (sources)", names: devices.sources,
                 verdict: selection.map { s in { s.input($0) } },
                 missing: selection?.unmatchedInputPatterns(among: devices.sources) ?? [])
    print("")
    printDevices("MIDI outputs (destinations)", names: devices.destinations,
                 verdict: selection.map { s in { s.output($0) } },
                 missing: selection?.unmatchedOutputPatterns(among: devices.destinations) ?? [])
}

func printDevices(
    _ title: String,
    names: [String],
    verdict: ((String) -> EndpointSelection.Verdict)?,
    missing: [String]
) {
    print("\(title):")
    if names.isEmpty {
        print("  (none)")
    }
    for name in names {
        switch verdict?(name) {
        case .connected(let pattern?):
            print("  \(name)  — matched by \"\(pattern)\"")
        case .connected(nil):
            print("  \(name)  — connected (no \"inputs\" in config: all devices)")
        case .ignored(let pattern):
            print("  \(name)  — ignored by \"\(pattern)\"")
        case .notMatched, nil:
            print("  \(name)")
        }
    }
    for pattern in missing {
        print("  (nothing matches \"\(pattern)\")")
    }
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

switch arguments.first {
case nil:
    printUsage()
    exit(1)
case "-h", "--help":
    printUsage()
    exit(0)
case "--list-devices":
    guard arguments.count <= 2 else {
        printUsage()
        exit(1)
    }
    do {
        try listDevices(configPath: arguments.count == 2 ? arguments[1] : nil)
    } catch {
        fail(error)
    }
    exit(0)
case "--init":
    guard arguments.count == 2 else {
        printUsage()
        exit(1)
    }
    do {
        try initTemplate(scriptPath: arguments[1])
    } catch {
        fail(error)
    }
    exit(0)
case let option? where option.hasPrefix("-"):
    printUsage()
    exit(1)
default:
    guard arguments.count == 1 else {
        printUsage()
        exit(1)
    }
}

let engine: Engine
do {
    engine = try Engine(configPath: arguments[0])
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

withExtendedLifetime(engine) {
    dispatchMain()
}
