import Foundation
import Midimend

let arguments = Array(CommandLine.arguments.dropFirst())

func printUsage() {
    print("""
    usage: midimend <config.json>
           midimend --list-devices [config.json]

    Mends MIDI between CoreMIDI ports by running a JavaScript processing
    script per event. See README.md for the config file format and script API.

    --list-devices  print the MIDI devices currently present; given a config,
                    also show which of them its "hardware" entries match
    """)
}

func fail(_ error: Error) -> Never {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

func listDevices(configPath: String?) throws {
    var setup: MIDISetup?
    if let configPath {
        setup = try Config.load(from: URL(fileURLWithPath: configPath).standardizedFileURL).midi
    }
    let devices = DeviceList.current()
    printDevices("MIDI inputs (sources)", names: devices.sources,
                 patterns: setup?.inputs.compactMap(\.hardware))
    print("")
    printDevices("MIDI outputs (destinations)", names: devices.destinations,
                 patterns: setup?.outputs.compactMap(\.hardware))
}

func printDevices(_ title: String, names: [String], patterns: [String]?) {
    print("\(title):")
    if names.isEmpty {
        print("  (none)")
    }
    for name in names {
        if let pattern = patterns?.first(where: { midiNameMatches(name, pattern: $0) }) {
            print("  \(name)  — matched by \"\(pattern)\"")
        } else {
            print("  \(name)")
        }
    }
    for pattern in patterns ?? [] where !names.contains(where: { midiNameMatches($0, pattern: pattern) }) {
        print("  (nothing matches \"\(pattern)\")")
    }
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
