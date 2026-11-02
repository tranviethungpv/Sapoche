package app.sapoche

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader

/**
 * What the widgets are painted with. A widget cannot blur what is behind it, so it is given what the app's own pages have:
 * the colours of the cover, blended smoothly (a tiny copy of the cover, drawn large), darkened so that white words read, with
 * a glow of the cover's own colour in a corner.
 */
object WidgetArt {
    /** Kept widget pictures are drawn at this many pixels to the dp: enough to look sharp, small enough for a launcher to take. */
    private const val PX_PER_DP = 2f

    const val RADIUS_DP = 24f

    private const val TINY = 24

    /** A tiny, blurred copy of [cover]: what is drawn large behind the words. */
    fun tiny(cover: Bitmap): Bitmap {
        val side = minOf(cover.width, cover.height)
        val square = Bitmap.createBitmap(cover, (cover.width - side) / 2, (cover.height - side) / 2, side, side)
        val small = Bitmap.createScaledBitmap(square, TINY, TINY, true)
        return boxBlur(boxBlur(small))
    }

    private fun boxBlur(source: Bitmap): Bitmap {
        val w = source.width
        val h = source.height
        val pixels = IntArray(w * h)
        source.getPixels(pixels, 0, w, 0, 0, w, h)
        val out = IntArray(w * h)
        for (y in 0 until h) {
            for (x in 0 until w) {
                var a = 0; var r = 0; var g = 0; var b = 0; var n = 0
                for (dy in -1..1) for (dx in -1..1) {
                    val c = pixels[(y + dy).coerceIn(0, h - 1) * w + (x + dx).coerceIn(0, w - 1)]
                    a += Color.alpha(c); r += Color.red(c); g += Color.green(c); b += Color.blue(c); n++
                }
                out[y * w + x] = Color.argb(a / n, r / n, g / n, b / n)
            }
        }
        return Bitmap.createBitmap(out, w, h, Bitmap.Config.ARGB_8888)
    }

    /** The colour of a cover as a glow: its average, made vivid, and not so dark that it vanishes. */
    fun accent(tiny: Bitmap?): Int {
        if (tiny == null) return BRAND
        var r = 0L; var g = 0L; var b = 0L
        val pixels = IntArray(tiny.width * tiny.height)
        tiny.getPixels(pixels, 0, tiny.width, 0, 0, tiny.width, tiny.height)
        for (c in pixels) { r += Color.red(c); g += Color.green(c); b += Color.blue(c) }
        val n = pixels.size
        val hsv = FloatArray(3)
        Color.RGBToHSV((r / n).toInt(), (g / n).toInt(), (b / n).toInt(), hsv)
        hsv[1] = (hsv[1] * 1.25f).coerceIn(0.35f, 1f)
        hsv[2] = hsv[2].coerceIn(0.55f, 0.95f)
        return Color.HSVToColor(hsv)
    }

    const val BRAND = 0xFFD81B60.toInt()
    private const val PLUM = 0xFF2A1020.toInt()

    /**
     * The picture behind a widget of [widthDp] by [heightDp]: [tiny] spread over it (the brand colours when there is no
     * cover), a dark veil with a deeper foot, and a glow of [accent] in the top left corner, all with rounded corners.
     */
    fun background(widthDp: Int, heightDp: Int, tiny: Bitmap?, accent: Int): Bitmap {
        val w = (widthDp * PX_PER_DP).toInt().coerceAtLeast(2)
        val h = (heightDp * PX_PER_DP).toInt().coerceAtLeast(2)
        val layer = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(layer)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        if (tiny != null) {
            // Spread to cover the whole widget, centred, smoothed by the scaling
            val scale = maxOf(w / tiny.width.toFloat(), h / tiny.height.toFloat())
            val dw = tiny.width * scale
            val dh = tiny.height * scale
            paint.isFilterBitmap = true
            canvas.drawBitmap(tiny, null, RectF((w - dw) / 2, (h - dh) / 2, (w + dw) / 2, (h + dh) / 2), paint)
            paint.color = Color.argb(120, 8, 4, 10)
            canvas.drawRect(0f, 0f, w.toFloat(), h.toFloat(), paint)
        } else {
            paint.shader = LinearGradient(0f, 0f, w.toFloat(), h.toFloat(), intArrayOf(BRAND, PLUM), null, Shader.TileMode.CLAMP)
            canvas.drawRect(0f, 0f, w.toFloat(), h.toFloat(), paint)
            paint.shader = null
            paint.color = Color.argb(60, 0, 0, 0)
            canvas.drawRect(0f, 0f, w.toFloat(), h.toFloat(), paint)
        }
        // A deeper foot, where the words and buttons are
        paint.shader = LinearGradient(0f, h * 0.35f, 0f, h.toFloat(), Color.TRANSPARENT, Color.argb(130, 0, 0, 0), Shader.TileMode.CLAMP)
        canvas.drawRect(0f, 0f, w.toFloat(), h.toFloat(), paint)
        // The glow of the cover's own colour
        paint.shader = RadialGradient(w * 0.12f, h * 0.05f, maxOf(w, h) * 0.75f, Color.argb(110, Color.red(accent), Color.green(accent), Color.blue(accent)), Color.TRANSPARENT, Shader.TileMode.CLAMP)
        canvas.drawRect(0f, 0f, w.toFloat(), h.toFloat(), paint)
        return rounded(layer)
    }

    /** The cover itself filling the widget, with a veil at the foot for its words: the small widget. */
    fun cover(widthDp: Int, heightDp: Int, cover: Bitmap?, accent: Int): Bitmap {
        val w = (widthDp * PX_PER_DP).toInt().coerceAtLeast(2)
        val h = (heightDp * PX_PER_DP).toInt().coerceAtLeast(2)
        if (cover == null) return background(widthDp, heightDp, null, accent)
        val layer = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(layer)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { isFilterBitmap = true }
        val side = minOf(cover.width, cover.height)
        val scale = maxOf(w / side.toFloat(), h / side.toFloat())
        val dw = cover.width * scale
        val dh = cover.height * scale
        canvas.drawBitmap(cover, null, RectF((w - dw) / 2, (h - dh) / 2, (w + dw) / 2, (h + dh) / 2), paint)
        paint.shader = LinearGradient(0f, h * 0.38f, 0f, h.toFloat(), Color.TRANSPARENT, Color.argb(215, 0, 0, 0), Shader.TileMode.CLAMP)
        canvas.drawRect(0f, 0f, w.toFloat(), h.toFloat(), paint)
        return rounded(layer)
    }

    private fun rounded(layer: Bitmap): Bitmap {
        val out = Bitmap.createBitmap(layer.width, layer.height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val r = RADIUS_DP * PX_PER_DP
        canvas.drawRoundRect(RectF(0f, 0f, layer.width.toFloat(), layer.height.toFloat()), r, r, paint)
        paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
        canvas.drawBitmap(layer, 0f, 0f, paint)
        return out
    }
}
