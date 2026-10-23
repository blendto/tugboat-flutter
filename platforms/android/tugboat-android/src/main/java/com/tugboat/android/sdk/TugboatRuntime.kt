package com.tugboat.android.sdk

import android.app.Activity
import android.app.Application
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.tugboat.android.TugboatConfig
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
import com.tugboat.android.host.SystemHostClock
import com.tugboat.android.views.ViewsAdapter
import com.tugboat.android.views.facts.FactSink
import com.tugboat.android.views.navigation.NavEntry
import com.tugboat.android.views.input.GestureConfig

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
    /** Coded events and network calls; any thread. */
    val evidence: EvidenceRecorder,
) {
    private var stopped = false

    fun setUserId(userId: String?) = host.post(SessionMessages.IDENTITY_SET, SessionMessages.identity(userId), clock.now())

    /** [traitsInput] is a [SessionMessages.traits] input. */
    fun setTraits(traitsInput: String) = host.post(SessionMessages.TRAITS_SET, traitsInput, clock.now())

    fun onNavDestination(activity: Activity, current: NavEntry, previous: NavEntry?) =
        adapter.onNavDestination(activity, current, previous)

    /**
     * Detaches every observer (pending facts are posted first), ends the
     * session, waits for its `session_end` post to settle, then disposes the
     * engine and the pixel runtime ([StopSequence]).
     */
    fun stop() {
        if (stopped) return
        stopped = true
        evidence.close()
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

        /**
         * Configures a new engine and starts a session; null (logged) when a
         * `session_start` field is missing or the engine library cannot load.
         */
        fun start(
            application: Application,
            config: TugboatConfig,
            sessionEpoch: Int,
            openTransport: () -> EngineTransport? = { JniEngineTransport.open() },
            stopSequence: StopSequence = StopSequence(),
        ): TugboatRuntime? {
            if (!config.enabled) return null
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
            return assemble(application, config, transport, device, metadata, sessionEpoch, stopSequence)
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
            sessionEpoch: Int,
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
            val watcher = SessionEndWatcher(HttpExecutor(hostConfig, frames::get))
            val gesture = GestureConfig.from(application)
            lateinit var host: EngineHost
            val adapter = ViewsAdapter(
                application = application,
                sink = FactSink { batch -> host.postBatch(batch) },
                gesture = gesture,
                postNavigationFacts = true,
            )
            val surfaces = SurfaceReporter { input -> host.post(SurfaceReporter.FACT_TYPE, input, clock.now()) }
            val foreground = ForegroundWindow(application, surfaces::observe)
            val main = Handler(Looper.getMainLooper())
            val captures = CaptureCoordinator(
                mainThread = main::post,
                window = { foreground.window },
                awaitWindow = foreground::awaitWindow,
                masks = adapter::masks,
                capturer = RuntimeWindowCapturer(),
                frames = frames,
                answer = { answer ->
                    host.post(HostMessages.CAPTURE_RESULT, answer.toInputJson(), clock.now(), answer.frameHandles)
                },
            )
            host = EngineHost.start(transport, frames, http = watcher, captures = captures)
            host.postUntimed(SessionMessages.ENGINE_CONFIGURE, EngineConfiguration.build(config, metadata, gesture).toString())
            host.post(
                SessionMessages.SESSION_START,
                SessionMessages.sessionStart(
                    device,
                    metadata,
                    sessionEpoch,
                    config.activationRequestId,
                    config.explorationRunId,
                ),
                clock.now(),
            )
            val lifecycle = AppLifecycleBridge(post = { state ->
                host.post(SessionMessages.APP_LIFECYCLE, SessionMessages.appLifecycle(state), clock.now())
            })
            val localeBridge = LocaleBridge(
                application = application,
                post = { input -> host.post(SessionMessages.LOCALE_SET, input, clock.now()) },
            )
            localeBridge.seedInitial(device.locale)
            val evidence = EvidenceRecorder(clock, EngineEvidenceEncoder, hostRunning = { host.isRunning }, post = host::post)
            adapter.start()
            foreground.start()
            lifecycle.start()
            localeBridge.start()
            return TugboatRuntime(host, adapter, lifecycle, localeBridge, foreground, captures, watcher, clock, stopSequence, evidence)
        }
    }
}
