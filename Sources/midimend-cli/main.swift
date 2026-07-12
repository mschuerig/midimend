import Foundation
import Midimend

let arguments = CommandLine.arguments

func printUsage() {
    print("""
    usage: midimend <config.json>

    Mends MIDI between CoreMIDI ports by running a JavaScript processing
    script per event. See README.md for the config file format and script API.
    """)
}

guard arguments.count == 2, !["-h", "--help"].contains(arguments[1]) else {
    printUsage()
    exit(arguments.count == 2 ? 0 : 1)
}

let engine: Engine
do {
    engine = try Engine(configPath: arguments[1])
    try engine.start()
    print("midimend running — Ctrl-C to quit")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
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
