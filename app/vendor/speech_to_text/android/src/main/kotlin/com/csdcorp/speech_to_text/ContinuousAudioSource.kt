package com.csdcorp.speech_to_text

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.Closeable

/** API33 audio-source contract: mono 16 kHz PCM16, EOF only on explicit release.
 * Nonblocking reads/writes prevent an engine ignoring the pipe from retaining
 * a blocked capture thread. No audio is persisted or sent to a remote service.
 */
internal class ContinuousAudioSource : Closeable {
    private val pipe = ParcelFileDescriptor.createPipe()
    val reader: ParcelFileDescriptor get() = pipe[0]
    @Volatile private var closed = false
    private var worker: Thread? = null

    init {
        try {
            val fd = pipe[1].fileDescriptor
            Os.fcntlInt(fd, OsConstants.F_SETFL,
                Os.fcntlInt(fd, OsConstants.F_GETFL, 0) or OsConstants.O_NONBLOCK)
        } catch (error: Exception) {
            close()
            throw error
        }
    }

    fun start(onFailure: () -> Unit) {
        check(worker == null && !closed)
        val bufferSize = maxOf(3200, AudioRecord.getMinBufferSize(16000,
            AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT))
        val recorder = AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION,
            16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, bufferSize)
        try {
            check(recorder.state == AudioRecord.STATE_INITIALIZED)
            recorder.startRecording()
            check(recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING)
        } catch (error: Exception) {
            recorder.release()
            throw error
        }
        worker = Thread({
            try {
                val buffer = ByteArray(bufferSize)
                while (!closed) {
                    val count = recorder.read(buffer, 0, buffer.size, AudioRecord.READ_NON_BLOCKING)
                    check(count >= 0) { "PCM capture failed" }
                    var offset = 0
                    while (!closed && offset < count) {
                        try {
                            // Serialize close against nonblocking writes so a recycled fd
                            // can never receive PCM belonging to an older capture.
                            val written = synchronized(this) {
                                if (closed) 0 else Os.write(pipe[1].fileDescriptor, buffer, offset, count - offset)
                            }
                            if (closed) break
                            check(written > 0) { "PCM pipe closed" }
                            offset += written
                        } catch (error: ErrnoException) {
                            if (error.errno != OsConstants.EAGAIN && error.errno != OsConstants.EINTR) throw error
                            Thread.sleep(10)
                        }
                    }
                    if (count == 0) Thread.sleep(10)
                }
            } catch (error: Exception) {
                if (!closed) onFailure()
            } finally {
                try { recorder.stop() } catch (_: Exception) { }
                recorder.release()
            }
        }, "local-dictation-pcm")
        try {
            worker!!.start()
        } catch (error: Exception) {
            try { recorder.stop() } catch (_: Exception) { }
            recorder.release()
            throw error
        }
    }

    /** Closing the writer signals EOF; cancellation also closes our read end.
     * The recognizer owns its IPC-duplicated descriptor until it is destroyed.
     */
    @Synchronized
    override fun close() {
        closed = true
        worker?.interrupt()
        try { pipe[1].close() } catch (_: Exception) { }
        try { pipe[0].close() } catch (_: Exception) { }
    }
}
