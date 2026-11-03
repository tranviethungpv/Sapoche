package app.sapoche

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.Effect
import androidx.media3.effect.FrameDropEffect
import androidx.media3.effect.Presentation
import androidx.media3.effect.ScaleAndRotateTransformation
import androidx.media3.transformer.AudioEncoderSettings
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.math.min

/**
 * Squeezes a video of the phone to what the chat can send: a light MP4 of H.264 and AAC, far under a given number of
 * bytes, with a poster. A chat video is looked at on a phone for a few seconds, so it is made soft on purpose: 480p at most
 * and 24 frames a second; a longer one is scaled down step by step, and one too long for even the smallest step to fit is
 * refused. The encoders are the phone's own (hardware).
 */
class VideoCompressor(private val context: Context) {

    /** A video squeezed: where it is, its size as it is shown (upright), its length and a poster (JPEG). */
    class Result(val path: String, val w: Int, val h: Int, val durMs: Long, val poster: ByteArray)

    /** Why a video was not made: [code] is `video_unreadable` or `video_too_big`. */
    class Failure(val code: String) : Exception(code)

    private class Facts(
        val durMs: Long,
        val w: Int,
        val h: Int,
        val hasAudio: Boolean,
        val container: String,
        val h264: Boolean,
        val aac: Boolean,
    ) {
        val shortSide get() = min(w, h)
    }

    /** A size the video can be scaled to: its short side, the bit rate that is plenty there and the least that still looks right. */
    private class Step(val shortSide: Int, val plenty: Int, val least: Int)

    /** With [mirror] the picture is turned left to right, as a selfie needs (the camera saves it the other way round from its preview). */
    suspend fun prepare(inputPath: String, maxBytes: Long, mirror: Boolean = false): Result {
        val facts = withContext(Dispatchers.IO) { read(inputPath) }
        val poster = withContext(Dispatchers.IO) { poster(inputPath, facts.durMs, mirror) } ?: throw Failure("video_unreadable")
        val budget = (maxBytes * BUDGET).toLong()
        val folder = File(context.cacheDir, "video-out").apply { mkdirs() }
        val out = File(folder, "${UUID.randomUUID()}.mp4")
        val input = File(inputPath)

        // Already what the chat wants and light enough: nothing is gained by squeezing it again
        if (!mirror && facts.container in MP4_LIKE && facts.h264 && (facts.aac || !facts.hasAudio) && input.length() <= LIGHT_ENOUGH && facts.shortSide <= STEPS.first().shortSide) {
            withContext(Dispatchers.IO) { input.copyTo(out, overwrite = true) }
            return Result(out.path, facts.w, facts.h, facts.durMs, poster)
        }

        val audioBps = if (facts.hasAudio) AUDIO_BPS else 0
        // What is left for the picture once the sound and the container are paid for
        var available = (budget * 8.0 / (facts.durMs / 1000.0) * 0.97 - audioBps).toInt()
        var attempt = 0
        while (true) {
            val step = STEPS.firstOrNull { available >= it.least && (it.shortSide <= facts.shortSide || it === STEPS.last()) }
                ?: throw Failure("video_too_big")
            // Not scaled up, and not given more bits than the size has use for
            val scale = if (step.shortSide < facts.shortSide) step.shortSide else null
            val bps = min(available, step.plenty)
            export(inputPath, out, bps, scale, audioBps, mirror)
            val size = out.length()
            if (size in 1..maxBytes) {
                val (w, h) = shown(facts, scale)
                // What was made says how long it is: the end of a screen recording that stands still is not kept
                return Result(out.path, w, h, withContext(Dispatchers.IO) { lengthOf(out.path) } ?: facts.durMs, poster)
            }
            out.delete()
            // The encoder gave more than it was asked for: ask for less
            if (++attempt > RETRIES) throw Failure("video_too_big")
            available = (available * 0.75).toInt()
        }
    }

    /** How long the video at [path] is, in milliseconds; null when it cannot be read. */
    private fun lengthOf(path: String): Long? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()?.takeIf { it > 0 }
        } catch (e: Exception) {
            null
        } finally {
            retriever.release()
        }
    }

    private fun shown(facts: Facts, scale: Int?): Pair<Int, Int> {
        if (scale == null) return facts.w to facts.h
        val factor = scale.toDouble() / facts.shortSide
        // The encoders take even sizes
        fun even(v: Double) = ((v.toInt() + 1) / 2) * 2
        return even(facts.w * factor) to even(facts.h * factor)
    }

    private fun read(path: String): Facts {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            fun number(key: Int) = retriever.extractMetadata(key)?.toLongOrNull() ?: 0L
            val rotation = number(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION).toInt()
            var w = number(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH).toInt()
            var h = number(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT).toInt()
            if (rotation == 90 || rotation == 270) w = h.also { h = w }
            val durMs = number(MediaMetadataRetriever.METADATA_KEY_DURATION)
            if (durMs <= 0 || w <= 0 || h <= 0) throw Failure("video_unreadable")
            val hasAudio = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes"
            val container = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE).orEmpty()
            var h264 = false
            var aac = false
            val extractor = MediaExtractor()
            try {
                extractor.setDataSource(path)
                for (i in 0 until extractor.trackCount) {
                    when (extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME)) {
                        MimeTypes.VIDEO_H264 -> h264 = true
                        MimeTypes.AUDIO_AAC -> aac = true
                    }
                }
            } finally {
                extractor.release()
            }
            return Facts(durMs, w, h, hasAudio, container, h264, aac)
        } catch (e: Failure) {
            throw e
        } catch (e: Exception) {
            // A format the phone does not know, or a damaged file
            throw Failure("video_unreadable")
        } finally {
            retriever.release()
        }
    }

    /** A frame a little way in (the first is often black), at most 480 px on its longer side, as a JPEG. */
    private fun poster(path: String, durMs: Long, mirror: Boolean): ByteArray? {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val at = min(1_000L, durMs / 10) * 1000
            val frame = retriever.getFrameAtTime(at, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: retriever.getFrameAtTime(0) ?: return null
            val longer = maxOf(frame.width, frame.height)
            val f = if (longer > POSTER_SIDE) POSTER_SIDE.toDouble() / longer else 1.0
            val scaled = if (f < 1.0 || mirror) {
                val turn = Matrix().apply { if (mirror) postScale(-1f, 1f, frame.width / 2f, 0f) }
                // One pass scales and turns
                Bitmap.createBitmap(frame, 0, 0, frame.width, frame.height, turn.apply { postScale(f.toFloat(), f.toFloat()) }, true)
            } else {
                frame
            }
            val bytes = ByteArrayOutputStream().also { scaled.compress(Bitmap.CompressFormat.JPEG, 75, it) }.toByteArray()
            if (scaled !== frame) scaled.recycle()
            frame.recycle()
            return bytes
        } catch (e: Exception) {
            return null
        } finally {
            retriever.release()
        }
    }

    /** One run of the encoder: [videoBps] for the picture, scaled so that the short side is [scale] where that is set. */
    private suspend fun export(inputPath: String, out: File, videoBps: Int, scale: Int?, audioBps: Int, mirror: Boolean) {
        // The Transformer works on the main thread, where a Looper is
        withContext(Dispatchers.Main) {
            suspendCancellableCoroutine { done ->
                val effects = ArrayList<Effect>()
                // A phone that films at 60 does not need all of it to be watched in a chat
                effects += FrameDropEffect.createDefaultFrameDropEffect(MAX_FPS)
                // The picture is upright by now, so left and right are the ones the person saw
                if (mirror) effects += ScaleAndRotateTransformation.Builder().setScale(-1f, 1f).build()
                if (scale != null) effects += Presentation.createForShortSide(scale)
                val item = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(File(inputPath))))
                    .setEffects(Effects(emptyList<AudioProcessor>(), effects))
                    .build()
                val encoders = DefaultEncoderFactory.Builder(context)
                    .setRequestedVideoEncoderSettings(
                        VideoEncoderSettings.Builder()
                            .setBitrate(videoBps)
                            // Far apart key frames are the cheap ones, and High profile spends fewer bits for the same picture
                            .setiFrameIntervalSeconds(3f)
                            .setEncodingProfileLevel(MediaCodecInfo.CodecProfileLevel.AVCProfileHigh, MediaCodecInfo.CodecProfileLevel.AVCLevel31)
                            .build(),
                    )
                    .setRequestedAudioEncoderSettings(AudioEncoderSettings.Builder().setBitrate(audioBps.coerceAtLeast(AUDIO_BPS)).build())
                    .build()
                val transformer = Transformer.Builder(context)
                    .setVideoMimeType(MimeTypes.VIDEO_H264)
                    .setAudioMimeType(MimeTypes.AUDIO_AAC)
                    .setEncoderFactory(encoders)
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                            if (done.isActive) done.resume(Unit)
                        }

                        override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                            EventLog.d("video", "export failed: ${exportException.errorCodeName}: ${exportException.message}")
                            if (done.isActive) done.resumeWithException(Failure("video_unreadable"))
                        }
                    })
                    .build()
                done.invokeOnCancellation { transformer.cancel() }
                transformer.start(item, out.path)
            }
        }
    }

    private companion object {
        /** The share of the limit aimed at: encoders overshoot a little, and the container has its own bytes. */
        const val BUDGET = 0.93

        /** How many times it is tried again with less when the encoder gave more than the limit. */
        const val RETRIES = 2
        const val AUDIO_BPS = 48_000
        const val MAX_FPS = 24f

        /** A video already an MP4 of H.264 that weighs no more than this (1.5 MB) and is no bigger than the lightest step is sent as it is. */
        const val LIGHT_ENOUGH = 1_500_000L
        const val POSTER_SIDE = 480

        /** From the best to the least: what a video of a given length can have within the limit. Soft on purpose. */
        val STEPS = listOf(
            Step(480, 650_000, 380_000),
            Step(360, 400_000, 230_000),
            Step(240, 230_000, 130_000),
            Step(180, 130_000, 70_000),
        )

        val MP4_LIKE = setOf("video/mp4", "video/quicktime", "video/3gpp")
    }
}
