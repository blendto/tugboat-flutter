package com.tugboat.android.sdk

import android.app.Application
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.tugboat.android.TugboatConfig
import com.tugboat.android.capture.CaptureAnswer
import com.tugboat.android.capture.CaptureCoordinator
import com.tugboat.android.capture.ForegroundWindow
import com.tugboat.android.capture.RuntimeWindowCapturer
import com.tugboat.android.capture.SurfaceReporter
import com.tugboat.android.engine.EngineTransport
import com.tugboat.android.engine.JniEngineTransport
import com.tugboat.android.evidence.EvidenceRecorder
import com.tugboat.android.evidence.EngineEvidenceEncoder
import com.tugboat.android.host.EngineHost
import com.tugboat.android.host.FrameHandleTable
import com.tugboat.android.host.HostClock
import com.tugboat.android.host.HostConfig
import com.tugboat.android.host.HostMessages
import com.tugboat.android.host.HttpExecutor
import com.tugboat.android.host.HttpSender
import com.tugboat.android.outbox.Outbox
import com.tugboat.android.outbox.OutboxDrainer
import com.tugboat.android.outbox.OutboxIdentityInputs
import com.tugboat.android.outbox.OutboxSender
import com.tugboat.android.outbox.OutboxSettings
import com.tugboat.android.outbox.Outboxes
import com.tugboat.android.host.SystemHostClock
import com.tugboat.android.views.ViewsAdapter
import com.tugboat.android.views.facts.FactSink
import com.tugboat.android.views.input.GestureConfig
import com.tugboat.android.views.navigation.NavigationObservation

/**
 * One running SDK: the engine host, the Views adapter, the capture
 * coordinator, the foreground window, and the process lifecycle bridge,
 * wired together. Created by [start] (the composition root); main thread
 * only. It owns one engine handle from `engine.configure` to
 * `engine.dispose`.
 */
internal class TugboatRuntime private constructor(
    private val host: EngineHost,
    private val adapter: ViewsAdapter,
    private val lifecycle: AppLifecycleBridge,
    private val locale: LocaleBridge,
    private val foreground: ForegroundWindow,
    private val captures: CaptureCoordinator,
    private val watcher: SessionEndWatcher,
    private val clock: HostClock,
    private val stopSequence: StopSequence,
    /** Replays the durable outbox while this session runs; null when [TugboatConfig.durableOutbox] is off. */
    private val drainer: OutboxDrainer?,
    /** `TUGBOAT_LAUNCH` / `TUGBOAT_HEALTH`'s `captureSessionId`: `session-<wallUs>` of `session.start`. */
    val captureSessionId: String,
    /** Coded events and network calls; any thread. */
    val evidence: EvidenceRecorder,
) {
    private var stopped = false

    /** Whether the engine host still runs (it stops on a fatal engine status). */
    val isHostRunning: Boolean
        get() = host.isRunning

    fun setUserId(userId: String?) = host.post(SessionMessages.IDENTITY_SET, SessionMessages.identity(userId), clock.now())

    /** [traitsInput] is a [SessionMessages.traits] input. */
    fun setTraits(traitsInput: String) = host.post(SessionMessages.TRAITS_SET, traitsInput, clock.now())

    /**
     * Detaches every observer (pending facts are posted first), ends the
     * session, waits for its `session_end` post to settle, then disposes the
     * engine and the pixel runtime ([StopSequence]).
     */
    fun stop() {
        if (stopped) return
        stopped = true
        evidence.close()
        drainer?.stop()
        adapter.stop()
        lifecycle.stop()
        locale.stop()
        foreground.stop()
        stopSequence.run(
            watcher = watcher,
            endSession = { host.post(SessionMessages.SESSION_END, SessionMessages.sessionEnd(), clock.now()) },
            finish = {
                host.close()
                captures.dispose()
            },
        )
    }

    companion object {
        private const val TAG = "Tugboat"

        /** `app.lifecycle` states after which the outbox flushes at once (W11 design 3, H1 mitigation). */
        private val BACKGROUND_STATES = setOf("paused", "hidden")

        /** The outbox drainer, on its own thread and its own [HttpExecutor] (never the engine's IO thread). */
        private fun replayDrainer(outbox: Outbox, hostConfig: HostConfig, identity: OutboxIdentityInputs): OutboxDrainer {
            val replay = HttpExecutor(hostConfig, outbox.store::readFrame)
            return OutboxDrainer(outbox, identity, replay::perform, onStop = replay::close)
        }

        /**
         * Configures a new engine and starts a session; null (logged) when a
         * `session_start` field is missing or the engine library cannot load.
         */
        fun start(
            application: Application,
            config: TugboatConfig,
            sessionEpoch: Int,
            /** From `Tugboat.activate`; passed on `session.start` when non-blank. */
            activationRequestId: String? = null,
            openTransport: () -> EngineTransport? = { JniEngineTransport.open() },
            stopSequence: StopSequence = StopSequence(),
        ): TugboatRuntime? {
            val device = DeviceSnapshot.read(application)
            val metadata = HostMetadata(config.app, device)
            val missing = metadata.missingFields() + collectorProblems(config)
            if (missing.isNotEmpty()) {
                Log.e(TAG, "Tugboat not started: required session_start fields are missing: $missing")
                return null
            }
            val transport = openTransport() ?: run {
                Log.e(TAG, "Tugboat not started: the session engine is unavailable")
                return null
            }
            val session = SessionInputs(sessionEpoch, activationRequestId)
            return assemble(application, config, transport, device, metadata, session, stopSequence)
        }

        /**
         * The required `session_start` fields [config] leaves blank (with the
         * device's), as paths; empty when a session can start. Logs them.
         */
        fun refusal(application: Application, config: TugboatConfig): List<String> {
            val missing = HostMetadata(config.app, DeviceSnapshot.read(application)).missingFields() +
                collectorProblems(config)
            if (missing.isNotEmpty()) {
                Log.e(TAG, "Tugboat not started: required session_start fields are missing: $missing")
            }
            return missing
        }

        private fun collectorProblems(config: TugboatConfig): List<String> = buildList {
            if (config.collector.baseUrl.isBlank()) add("collector.baseUrl")
            if (config.collector.apiKey.isBlank()) add("collector.apiKey")
        }

        private fun assemble(
            application: Application,
            config: TugboatConfig,
            transport: EngineTransport,
            device: DeviceSnapshot,
            metadata: HostMetadata,
            session: SessionInputs,
            stopSequence: StopSequence,
        ): TugboatRuntime {
            val clock = SystemHostClock
            val frames = FrameHandleTable()
            val hostConfig = HostConfig(
                collectorBaseUrl = config.collector.baseUrl,
                apiKey = config.collector.apiKey,
                appVersion = config.app.version,
                appBuild = config.app.buildNumber,
                appId = config.app.appId,
            )
            val outbox = if (config.durableOutbox) Outboxes.at(application) else null
            outbox?.settings = OutboxSettings.of(config)
            val outboxIdentity = OutboxIdentityInputs(config.collector.baseUrl, config.app.appId, config.collector.apiKey)
            val delivery = HttpExecutor(hostConfig, frames::get)
            val sender: HttpSender = outbox?.let {
                OutboxSender(delivery, it, outboxIdentity, hostConfig.sdkVersion, frames::get)
            } ?: delivery
            val watcher = SessionEndWatcher(sender)
            val gesture = GestureConfig.from(application)
            val engineHost = EngineHostSlot()
            val adapter = ViewsAdapter(
                application = application,
                sink = FactSink { batch -> engineHost.withHost { it.postBatch(batch) } },
                gesture = gesture,
                postNavigationFacts = true,
                emitSceneInventory = config.emitSceneInventory,
            )
            val surfaces = SurfaceReporter { input ->
                engineHost.withHost { it.post(SurfaceReporter.FACT_TYPE, input, clock.now()) }
            }
            val startAt = clock.now()
            val foreground = ForegroundWindow(
                application,
                resumedActivity = NavigationObservation::resumedActivity,
                onBoundary = surfaces::observe,
            )
            val main = Handler(Looper.getMainLooper())
            val captures = CaptureCoordinator(
                mainThread = main::post,
                window = { foreground.window },
                awaitWindow = foreground::awaitWindow,
                masks = adapter::masks,
                capturer = RuntimeWindowCapturer(),
                frames = frames,
                answer = { answer ->
                    engineHost.withHost {
                        it.post(HostMessages.CAPTURE_RESULT, answer.toInputJson(), clock.now(), answer.frameHandles)
                    }
                    if (answer is CaptureAnswer.Captured) {
                        val frame = answer.frame
                        adapter.onCaptureCompleted(frame.structureSignature, frame.hasRegionHosts, main::post) { foreground.window }
                    }
                },
            )
            val host = EngineHost.start(transport, frames, http = watcher, captures = captures)
            engineHost.value = host
            host.postUntimed(SessionMessages.ENGINE_CONFIGURE, EngineConfiguration.build(config, metadata, gesture).toString())
            host.post(
                SessionMessages.SESSION_START,
                SessionMessages.sessionStart(
                    device,
                    metadata,
                    session.sessionEpoch,
                    session.activationRequestId,
                    config.explorationRunId,
                ),
                startAt,
            )
            val drainer = outbox?.let { replayDrainer(it, hostConfig, outboxIdentity) }
            drainer?.start()
            val lifecycle = AppLifecycleBridge(post = { state ->
                host.post(SessionMessages.APP_LIFECYCLE, SessionMessages.appLifecycle(state), clock.now())
                // With the outbox on, what waits for the flush timer is sent (and kept) before the app may die.
                if (outbox != null && state in BACKGROUND_STATES) {
                    host.post(SessionMessages.TRANSPORT_FLUSH, "{}", clock.now())
                }
            })
            val localeBridge = LocaleBridge(
                application = application,
                initial = device.locale,
                post = { input -> host.post(SessionMessages.LOCALE_SET, input, clock.now()) },
            )
            val evidence = EvidenceRecorder(clock, EngineEvidenceEncoder, hostRunning = { host.isRunning }, post = host::post)
            adapter.start()
            foreground.start()
            lifecycle.start()
            localeBridge.start()
            return TugboatRuntime(
                host, adapter, lifecycle, localeBridge, foreground, captures, watcher, clock, stopSequence, drainer,
                LaunchCorrelation.captureSessionId(startAt.wallUs), evidence,
            )
        }
    }
}

/** What differs between sessions of one config. */
private class SessionInputs(
    val sessionEpoch: Int,
    val activationRequestId: String?,
)

internal fun String?.normalizedSessionId(): String? = this?.takeIf { it.isNotBlank() }

/** Holds the engine host while capture wiring is constructed. */
private class EngineHostSlot {
    @Volatile var value: EngineHost? = null

    inline fun withHost(block: (EngineHost) -> Unit) {
        val current = value
        if (current != null) block(current)
    }
}
