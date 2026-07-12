import Foundation

/// Glues config, CoreMIDI I/O, and the script engine together.
///
/// All script access is confined to `jsQueue`; CoreMIDI callbacks only enqueue.
/// Config and script files are watched and hot-reloaded (a reload re-fires
/// ParameterChanged for every parameter, as when a plug-in setting is loaded).
/// MIDI port changes require a restart.
public final class Engine: @unchecked Sendable {
    private let configURL: URL
    private var config: Config
    private let jsQueue = DispatchQueue(label: "midimend.js", qos: .userInteractive)
    private var midi: MIDIIO?
    private var scriptEngine: ScriptEngine?
    private var idleTimer: DispatchSourceTimer?
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var reloadScheduled = false

    public init(configPath: String) throws {
        self.configURL = URL(fileURLWithPath: configPath).standardizedFileURL
        self.config = try Config.load(from: configURL)
    }

    public func start() throws {
        let midi = try MIDIIO(setup: config.midi, receive: { [weak self] bytes, port in
            guard let self else { return }
            self.jsQueue.async { self.scriptEngine?.handleIncoming(bytes, port: port) }
        })
        self.midi = midi
        try jsQueue.sync {
            self.scriptEngine = try self.makeScriptEngine()
            self.installWatchers()
        }
        startIdleTimer()
    }

    private func makeScriptEngine() throws -> ScriptEngine {
        let scriptURL = config.scriptURL(relativeTo: configURL)
        let source: String
        do {
            source = try String(contentsOf: scriptURL, encoding: .utf8)
        } catch {
            throw MidimendError.script("cannot read script \(scriptURL.path): \(error.localizedDescription)")
        }
        return try ScriptEngine(
            script: source,
            scriptName: scriptURL.lastPathComponent,
            configParameters: config.parameters ?? [:],
            send: { [weak self] bytes in self?.midi?.send(bytes) },
            trace: { message in print(message) },
            schedule: { [weak self] delayMs, action in
                self?.jsQueue.asyncAfter(deadline: .now() + delayMs / 1000.0, execute: action)
            }
        )
    }

    // MARK: - Idle (fires roughly every 0.25 s)

    private func startIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: jsQueue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.scriptEngine?.idleTick() }
        timer.resume()
        idleTimer = timer
    }

    // MARK: - Hot reload

    private func installWatchers() {
        for watcher in watchers { watcher.cancel() }
        watchers.removeAll()
        let scriptURL = config.scriptURL(relativeTo: configURL)
        for url in [configURL, scriptURL] {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .rename, .delete],
                queue: jsQueue
            )
            source.setEventHandler { [weak self] in self?.scheduleReload() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watchers.append(source)
        }
    }

    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        // Debounce: editors often produce several events per save.
        jsQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.performReload() }
    }

    private func performReload() {
        reloadScheduled = false
        do {
            let newConfig = try Config.load(from: configURL)
            if newConfig.midi != config.midi {
                print("note: MIDI port configuration changed — restart to apply")
            }
            config = newConfig
            scriptEngine = try makeScriptEngine()
            print("Reloaded \(config.script)")
        } catch {
            print("Reload failed: \(error) — keeping previous script")
        }
        // Re-arm: atomic saves replace the file, invalidating watched descriptors.
        installWatchers()
    }
}
