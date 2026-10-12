package com.tugboat.android.capture

import android.util.Log
import android.view.View
import android.view.Window
import com.tugboat.android.host.CaptureRequestEffect
import com.tugboat.android.host.CaptureRequestSink
import com.tugboat.android.host.FrameHandleTable
import com.tugboat.android.views.mask.WindowMaskResult
import com.tugboat.capture.CaptureRequest
import com.tugboat.capture.CaptureResult
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * Performs the engine's `capture.request` effects (stateful-engine.md 8.2).
 *
 * - The request arrives on the engine thread and hops to the main thread,
 *   where the foreground window and its size (for the frame's pixel size)
 *   are read.
 * - The pixel runtime waits for a committed frame, then calls [FrameMasks]
 *   on the main thread immediately before `PixelCopy.request`: masks (fail
 *   closed, `views/mask/WindowMasks`), the motion check, the structure
 *   signature, and the boundary all describe the copied frame. It fills the
 *   masks before encoding and completes on its own thread; the JPEG goes
 *   into the handle table.
 * - **Every request is answered exactly once, by id (C16).** Requests may
 *   overlap (the engine abandons a capture at teardown or at its C18 answer
 *   deadline and may issue the next one while the host still works on the
 *   earlier); each is tracked by its own runtime id and answered whenever its
 *   runtime result arrives, in any order. A late answer is fine: the engine
 *   ignores it and releases its frame.
 * - Nothing thrown here reaches the app or the engine thread: a failure
 *   answers `failed` instead.
 */
internal class CaptureCoordinator(
    /** Runs a task on the main thread; false when it cannot be queued. */
    private val mainThread: (Runnable) -> Boolean,
    /** The window to capture: the foreground activity's, or null. */
    private val window: () -> Window?,
    /** Calls back once a foreground window exists, or after the timeout (main thread). */
    private val awaitWindow: (timeoutMs: Long, onDone: () -> Unit) -> Unit,
    private val masks: (Window) -> WindowMaskResult,
    private val capturer: WindowCapturer,
    frames: FrameHandleTable,
    private val answer: (CaptureAnswer) -> Unit,
    private val nanoTime: () -> Long = System::nanoTime,
) : CaptureRequestSink {
    private val outcomes = RuntimeOutcomes(frames, nanoTime)
    private val inFlight = ConcurrentHashMap<Long, InFlightCapture>()
    private val nextRuntimeId = AtomicLong()

    /** Captures handed to the runtime and not yet answered; for tests and diagnostics. */
    val pendingCount: Int
        get() = inFlight.size

    override fun onCaptureRequest(request: CaptureRequestEffect) {
        val receivedNanos = nanoTime()
        val queued = try {
            mainThread(Runnable { performOnMain(request, receivedNanos) })
        } catch (failure: Throwable) {
            Log.w(TAG, "could not reach the main thread", failure)
            false
        }
        if (!queued) send(CaptureAnswer.Failed(request.requestId, CaptureFailure.BoundaryUnavailable))
    }

    /** Disposes the runtime; captures still running answer `cancelled`. */
    fun dispose() {
        guard("dispose") { capturer.dispose() }
    }

    /**
     * [waited] records the one deferral of each kind a request gets: for a
     * foreground window (the session's `initial` capture is requested before
     * the first activity resumes) and for that window's first layout.
     */
    private fun performOnMain(request: CaptureRequestEffect, receivedNanos: Long, waited: Waited = Waited()) {
        val immediate = try {
            start(request, nextRuntimeId.incrementAndGet(), receivedNanos, waited)
        } catch (failure: Throwable) {
            // Thrown before the capture was registered: nobody else answers it.
            Log.w(TAG, "capture ${request.requestId} failed before the copy", failure)
            CaptureAnswer.Failed(request.requestId, CaptureFailure.MaskFailed)
        }
        immediate?.let(::send)
    }

    /**
     * Hands the capture to the runtime; returns an answer only when it cannot.
     * Registering in [inFlight] is the last step before the runtime call, and
     * whoever removes the entry answers, so the answer is sent once.
     */
    private fun start(
        request: CaptureRequestEffect,
        runtimeId: Long,
        receivedNanos: Long,
        waited: Waited,
    ): CaptureAnswer? {
        val startedNanos = nanoTime()
        val target = window()
        if (target == null) {
            if (waited.forWindow) return CaptureAnswer.Failed(request.requestId, CaptureFailure.BoundaryUnavailable)
            awaitWindow(WINDOW_WAIT_MS) { performOnMain(request, receivedNanos, waited.copy(forWindow = true)) }
            return null
        }
        val decor = target.peekDecorView()
        val geometry = CaptureGeometry.of(decor)
            ?: return if (!waited.forLayout && retryAfterLayout(request, decor, receivedNanos, waited)) {
                null
            } else {
                CaptureAnswer.Failed(request.requestId, CaptureFailure.LayoutUnavailable)
            }
        // A forced request must be answered with a fresh frame: it is never offered a baseline.
        // The runtime offers it to the dHash skip only if the copy-time structure matches.
        val baseline = request.dHashBaseline?.takeUnless { request.force }
        val frameMasks = FrameMasks(masks)
        val (width, height) = geometry.pixelSize(request.scale)
        inFlight[runtimeId] = InFlightCapture(
            requestId = request.requestId,
            requestGeometry = geometry,
            masks = frameMasks,
            offeredBaseline = baseline,
            frameWaitMicros = (startedNanos - receivedNanos) / NANOS_PER_MICRO,
            startedNanos = startedNanos,
        )
        val runtimeRequest = CaptureRequest(
            requestId = runtimeId,
            pixelWidth = width,
            pixelHeight = height,
            force = request.force,
            lastDHash = baseline?.dHash.orEmpty(),
            lastStructureSignature = baseline?.structureSignature.orEmpty(),
        )
        return try {
            capturer.capture(target, runtimeRequest, frameMasks, ::onRuntimeResult)
            null
        } catch (failure: Throwable) {
            Log.w(TAG, "capture ${request.requestId}: the runtime threw", failure)
            inFlight.remove(runtimeId)?.let { CaptureAnswer.Failed(it.requestId, CaptureFailure.ReadbackFailed) }
        }
    }

    /**
     * A window that just resumed is laid out by its first traversal, which
     * runs before a task posted to its attached decor view. True when the
     * request was re-queued that way (it is then answered by the retry).
     */
    private fun retryAfterLayout(request: CaptureRequestEffect, decor: View?, receivedNanos: Long, waited: Waited): Boolean =
        decor != null && decor.isAttachedToWindow &&
            decor.post { performOnMain(request, receivedNanos, waited.copy(forLayout = true)) }

    /** Runtime thread (or the caller's, for an immediate result). */
    private fun onRuntimeResult(result: CaptureResult) {
        val capture = inFlight.remove(result.requestId) ?: return
        val reply = try {
            outcomes.answer(capture, result)
        } catch (failure: Throwable) {
            Log.w(TAG, "capture ${capture.requestId} result could not be read", failure)
            CaptureAnswer.Failed(capture.requestId, CaptureFailure.EncodingFailed)
        }
        send(reply)
    }

    private fun send(reply: CaptureAnswer) = guard("answer ${reply.requestId}") { answer(reply) }

    private inline fun guard(what: String, block: () -> Unit) {
        try {
            block()
        } catch (failure: Throwable) {
            Log.w(TAG, "capture $what failed", failure)
        }
    }

    private data class Waited(val forWindow: Boolean = false, val forLayout: Boolean = false)

    private companion object {
        const val TAG = "TugboatCapture"

        /** Below the engine's 5 s C18 answer deadline, so the answer still counts. */
        const val WINDOW_WAIT_MS = 3_000L
        const val NANOS_PER_MICRO = 1_000L
    }
}
