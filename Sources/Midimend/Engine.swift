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
    private let log: @Sendable (String) -> Void
    private let jsQueue = DispatchQueue(label: "midimend.js", qos: .userInteractive)
    private var midi: MIDIIO?
    private var scriptEngine: ScriptEngine?
    private var idleTimer: DispatchSourceTimer?
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var reloadScheduled = false
    private var latencyStats: LatencyStats?  // touched on jsQueue only
    private var idleTicks = 0

    public init(
        configPath: String,
        measure: Bool = false,
        log: @escaping @Sendable (String) -> Void = { print($0) }
    ) throws {
        self.configURL = URL(fileURLWithPath: configPath).standardizedFileURL
        self.config = try Config.load(from: configURL)
        self.log = log
        if measure { self.latencyStats = LatencyStats() }
    }

    public func start() throws {
        let midi = try MIDIIO(setup: config.midi, receive: { [weak self] bytes, port, driverTime in
            guard let self else { return }
            self.jsQueue.async {
                if self.latencyStats == nil {
                    self.scriptEngine?.handleIncoming(bytes, port: port)
                } else {
                    let entry = mach_absolute_time()
                    self.scriptEngine?.handleIncoming(bytes, port: port)
                    let done = mach_absolute_time()
                    // Future-stamped events (apps scheduling ahead) would go
                    // negative; clamp to zero.
                    self.latencyStats?.record(
                        hopNanos: Self.nanoseconds(entry > driverTime ? entry - driverTime : 0),
                        totalNanos: Self.nanoseconds(done > driverTime ? done - driverTime : 0)
                    )
                }
            }
        }, log: log)
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
            trace: log,
            schedule: { [weak self] delayMs, action in
                guard let self else { return }
                Self.scheduleStrict(afterMilliseconds: delayMs, on: self.jsQueue, action: action)
            }
        )
    }

    // MARK: - Idle (fires roughly every 0.25 s)

    private func startIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: jsQueue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.scriptEngine?.idleTick()
            self.idleTicks += 1
            if self.idleTicks % 40 == 0, let line = self.latencyStats?.summarizeAndReset() {
                self.log(line)
            }
        }
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
                log("note: MIDI port configuration changed — restart to apply")
            }
            config = newConfig
            scriptEngine = try makeScriptEngine()
            log("Reloaded \(config.script)")
        } catch {
            log("Reload failed: \(error) — keeping previous script")
        }
        // Re-arm: atomic saves replace the file, invalidating watched descriptors.
        installWatchers()
    }

    // MARK: - Strict scheduling (sendAfterMilliseconds)

    /// One-shot timer that opts out of timer coalescing. asyncAfter offers no
    /// such opt-out, and the system leeway it allows grows with the process's
    /// priority tier; scheduled sends need to land on time.
    static func scheduleStrict(
        afterMilliseconds delayMs: Double,
        on queue: DispatchQueue,
        action: @escaping @Sendable () -> Void
    ) {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now() + delayMs / 1000.0, leeway: .nanoseconds(0))
        timer.setEventHandler {
            action()
            // The handler↔source cycle keeps the timer alive until here.
            timer.cancel()
        }
        timer.resume()
    }

    // MARK: - Host-time conversion (for --measure)

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    private static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        ticks * timebase.numer / timebase.denom
    }
}
