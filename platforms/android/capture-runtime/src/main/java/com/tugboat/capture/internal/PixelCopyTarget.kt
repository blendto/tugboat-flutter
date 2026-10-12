package com.tugboat.capture.internal

import android.annotation.TargetApi
import android.graphics.Bitmap
import android.os.Build
import android.os.Handler
import android.view.PixelCopy
import android.view.SurfaceView
import android.view.View
import android.view.Window
import com.tugboat.capture.CaptureStatus
import com.tugboat.capture.MaskSnapshot
import com.tugboat.capture.WindowMaskSupplier
import java.util.concurrent.atomic.AtomicReference

/** Called once with the copy's outcome: `Ok`, or why there is no frame. */
internal typealias CopyFinished = (CaptureStatus) -> Unit

/** The `PixelCopy.request` overload a resolved [CaptureSource] copies with. */
internal sealed interface PixelCopyTarget {
    /** Capture thread, before posting to the main thread. False: nothing to copy. */
    fun isAvailable(): Boolean

    /**
     * Main thread. Requests the copy into [destination] and reports through
     * [finish], or reports why it was not requested. May defer the request;
     * a deferred request re-checks [isCurrent] first.
     */
    fun issue(
        destination: Bitmap,
        handler: Handler,
        isCurrent: () -> Boolean,
        finish: CopyFinished,
    )
}

internal class SurfaceViewTarget(
    private val surfaceView: SurfaceView,
) : PixelCopyTarget {
    override fun isAvailable(): Boolean = surfaceView.holder.surface.isValid

    @TargetApi(Build.VERSION_CODES.N)
    override fun issue(
        destination: Bitmap,
        handler: Handler,
        isCurrent: () -> Boolean,
        finish: CopyFinished,
    ) = requestCopy(finish) { listener ->
        PixelCopy.request(surfaceView, destination, listener, handler)
    }
}

/** A target whose masks are computed on the main thread at copy time. */
internal interface MaskingTarget {
    /** The snapshot taken just before the copy was requested; null if none was requested. */
    val snapshot: MaskSnapshot?

    /** How long taking [snapshot] ran on the main thread. */
    val maskComputeMicros: Long
}

/**
 * A whole app window. `FLAG_SECURE` and the decor view are read
 * authoritatively here, on the main thread; capture-thread reads are only an
 * early exit. PixelCopy of a window returns its last queued buffer, which can
 * still hold a secure screen just after the flag is cleared, so the copy is
 * requested only after a frame drawn after the check has been committed, and
 * the flag is checked again at that point. The masks are taken from [masks]
 * in that same main-thread task, immediately before the request, so they
 * describe the frame being copied; a supplier that throws masks everything.
 */
internal class WindowTarget(
    private val window: Window,
    private val masks: WindowMaskSupplier = WindowMaskSupplier { MaskSnapshot(emptyList()) },
    private val frames: FrameWaiter = CommittedFrameWaiter,
    private val copy: WindowCopy = PlatformWindowCopy,
) : PixelCopyTarget, MaskingTarget {
    private val taken = AtomicReference<MaskSnapshot?>()
    private val supplierMicros = AtomicReference(0L)

    override val snapshot: MaskSnapshot?
        get() = taken.get()

    override val maskComputeMicros: Long
        get() = supplierMicros.get()

    override fun isAvailable(): Boolean = window.attachedDecor() != null

    override fun issue(
        destination: Bitmap,
        handler: Handler,
        isCurrent: () -> Boolean,
        finish: CopyFinished,
    ) {
        val decor = window.attachedDecor() ?: return finish(CaptureStatus.SurfaceUnavailable)
        if (window.isSecure()) return finish(CaptureStatus.SecureWindow)
        frames.afterNextFrame(decor) {
            when {
                !isCurrent() -> finish(CaptureStatus.Cancelled)
                window.isSecure() -> finish(CaptureStatus.SecureWindow)
                else -> {
                    takeMasks()
                    requestCopy(finish) { listener -> copy.request(window, destination, listener, handler) }
                }
            }
        }
    }

    /** Main thread; [issue] calls it right before requesting the copy. */
    internal fun takeMasks() {
        val start = System.nanoTime()
        val supplied =
            try {
                masks.masksFor(window)
            } catch (_: Throwable) {
                MaskSnapshot.WHOLE_FRAME
            }
        supplierMicros.set((System.nanoTime() - start) / 1_000)
        taken.set(supplied)
    }
}

/** `PixelCopy.request(Window, …)`; a seam so tests can observe ordering. */
internal fun interface WindowCopy {
    fun request(
        window: Window,
        destination: Bitmap,
        listener: PixelCopy.OnPixelCopyFinishedListener,
        handler: Handler,
    )
}

internal object PlatformWindowCopy : WindowCopy {
    @TargetApi(Build.VERSION_CODES.O)
    override fun request(
        window: Window,
        destination: Bitmap,
        listener: PixelCopy.OnPixelCopyFinishedListener,
        handler: Handler,
    ) = PixelCopy.request(window, destination, listener, handler)
}

/** Runs an action on the main thread once a newly drawn frame is committed. */
internal fun interface FrameWaiter {
    fun afterNextFrame(
        decor: View,
        action: Runnable,
    )
}

/**
 * API 29+ hardware-accelerated windows: `registerFrameCommitCallback`.
 * Otherwise two `postOnAnimation` frames: the first runs before the frame that
 * draws the invalidation, the second after it.
 */
internal object CommittedFrameWaiter : FrameWaiter {
    override fun afterNextFrame(
        decor: View,
        action: Runnable,
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && decor.isHardwareAccelerated) {
            decor.viewTreeObserver.registerFrameCommitCallback(action)
        } else {
            decor.postOnAnimation { decor.postOnAnimation(action) }
        }
        decor.invalidate()
    }
}

private inline fun requestCopy(
    noinline finish: CopyFinished,
    request: (PixelCopy.OnPixelCopyFinishedListener) -> Unit,
) {
    try {
        request { code -> finish(code.toCopyStatus()) }
    } catch (_: IllegalArgumentException) {
        finish(CaptureStatus.PixelCopyFailed)
    }
}

private fun Int.toCopyStatus(): CaptureStatus =
    when (this) {
        PixelCopy.SUCCESS -> CaptureStatus.Ok
        PixelCopy.ERROR_TIMEOUT -> CaptureStatus.Timeout
        else -> CaptureStatus.PixelCopyFailed
    }

private fun Window.attachedDecor(): View? = peekDecorView()?.takeIf { it.isAttachedToWindow }
