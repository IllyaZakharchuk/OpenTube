package com.example.opentube.dsp

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor.AudioFormat
import androidx.media3.common.audio.BaseAudioProcessor
import java.nio.ByteBuffer
import kotlin.math.*

enum class BandType { PEAK, LOW_SHELF, HIGH_SHELF, LOW_PASS, HIGH_PASS }

data class BandParams(
    val type: BandType = BandType.PEAK,
    val freq: Float = 1000f,
    val gainDb: Float = 0f,
    val q: Float = 1f,
    val enabled: Boolean = true,
)

data class DspConfig(
    val enabled: Boolean = true,
    val preampDb: Float = 0f,
    val bands: List<BandParams> = emptyList(),
    val tubeDrive: Float = 0f,
    val exciterAmount: Float = 0f,
    val stereoWidth: Float = 0.42f,
    val reverbMix: Float = 0.42f,
    val limiterCeilingDb: Float = -1.5f,
) {
    companion object {
        @Suppress("UNCHECKED_CAST")
        fun fromMap(m: Map<String, Any?>): DspConfig {
            fun f(k: String, d: Float) = (m[k] as? Number)?.toFloat() ?: d
            val bands = (m["bands"] as? List<Map<String, Any?>>)?.map { b ->
                BandParams(
                    type = BandType.values()[(b["type"] as? Number)?.toInt() ?: 0],
                    freq = (b["freq"] as Number).toFloat(),
                    gainDb = (b["gainDb"] as Number).toFloat(),
                    q = (b["q"] as Number).toFloat(),
                    enabled = b["enabled"] as? Boolean ?: true,
                )
            } ?: emptyList()
            return DspConfig(
                enabled = m["enabled"] as? Boolean ?: true,
                preampDb = f("preampDb", 0f),
                bands = bands,
                tubeDrive = f("tubeDrive", 0f),
                exciterAmount = f("exciterAmount", 0f),
                stereoWidth = f("stereoWidth", 0.42f),
                reverbMix = f("reverbMix", 0.42f),
                limiterCeilingDb = f("limiterCeilingDb", -1.5f),
            )
        }
    }
}

class Biquad {
    private var b0 = 1.0; private var b1 = 0.0; private var b2 = 0.0
    private var a1 = 0.0; private var a2 = 0.0
    private var x1 = 0.0; private var x2 = 0.0
    private var y1 = 0.0; private var y2 = 0.0

    fun configure(type: BandType, fs: Double, f0: Double, gainDb: Double, q: Double) {
        val freq = f0.coerceIn(10.0, fs * 0.45)
        val qq = q.coerceAtLeast(0.05)
        val a = 10.0.pow(gainDb / 40.0)
        val w0 = 2.0 * PI * freq / fs
        val cw = cos(w0)
        val alpha = sin(w0) / (2.0 * qq)
        val s = 2.0 * sqrt(a) * alpha
        val nb0: Double; val nb1: Double; val nb2: Double
        val na0: Double; val na1: Double; val na2: Double
        when (type) {
            BandType.PEAK -> {
                nb0 = 1 + alpha * a; nb1 = -2 * cw; nb2 = 1 - alpha * a
                na0 = 1 + alpha / a; na1 = -2 * cw; na2 = 1 - alpha / a
            }
            BandType.LOW_SHELF -> {
                nb0 = a * ((a + 1) - (a - 1) * cw + s)
                nb1 = 2 * a * ((a - 1) - (a + 1) * cw)
                nb2 = a * ((a + 1) - (a - 1) * cw - s)
                na0 = (a + 1) + (a - 1) * cw + s
                na1 = -2 * ((a - 1) + (a + 1) * cw)
                na2 = (a + 1) + (a - 1) * cw - s
            }
            BandType.HIGH_SHELF -> {
                nb0 = a * ((a + 1) + (a - 1) * cw + s)
                nb1 = -2 * a * ((a - 1) + (a + 1) * cw)
                nb2 = a * ((a + 1) + (a - 1) * cw - s)
                na0 = (a + 1) - (a - 1) * cw + s
                na1 = 2 * ((a - 1) - (a + 1) * cw)
                na2 = (a + 1) - (a - 1) * cw - s
            }
            BandType.LOW_PASS -> {
                nb0 = (1 - cw) / 2; nb1 = 1 - cw; nb2 = (1 - cw) / 2
                na0 = 1 + alpha; na1 = -2 * cw; na2 = 1 - alpha
            }
            BandType.HIGH_PASS -> {
                nb0 = (1 + cw) / 2; nb1 = -(1 + cw); nb2 = (1 + cw) / 2
                na0 = 1 + alpha; na1 = -2 * cw; na2 = 1 - alpha
            }
        }
        b0 = nb0 / na0; b1 = nb1 / na0; b2 = nb2 / na0
        a1 = na1 / na0; a2 = na2 / na0
    }

    fun process(x: Double): Double {
        val y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }

    fun reset() { x1 = 0.0; x2 = 0.0; y1 = 0.0; y2 = 0.0 }
}

class CombFilter(size: Int) {
    private val buffer = DoubleArray(size)
    private var idx = 0
    private var filterStore = 0.0

    fun process(input: Double, feedback: Double, damp: Double): Double {
        val output = buffer[idx]
        filterStore = output * (1.0 - damp) + filterStore * damp
        buffer[idx] = input + filterStore * feedback
        if (++idx >= buffer.size) idx = 0
        return output
    }

    fun reset() {
        buffer.fill(0.0)
        filterStore = 0.0
        idx = 0
    }
}

class AllpassFilter(size: Int) {
    private val buffer = DoubleArray(size)
    private var idx = 0

    fun process(input: Double): Double {
        val bufOut = buffer[idx]
        val output = -input + bufOut
        buffer[idx] = input + (bufOut * 0.5)
        if (++idx >= buffer.size) idx = 0
        return output
    }

    fun reset() {
        buffer.fill(0.0)
        idx = 0
    }
}

class SmallRoomReverb {
    private val combL = arrayOf(CombFilter(1116), CombFilter(1188), CombFilter(1277), CombFilter(1356))
    private val combR = arrayOf(CombFilter(1139), CombFilter(1211), CombFilter(1300), CombFilter(1379))
    private val allpassL = arrayOf(AllpassFilter(556), AllpassFilter(441))
    private val allpassR = arrayOf(AllpassFilter(579), AllpassFilter(464))

    fun process(inL: Double, inR: Double, mix: Double, out: DoubleArray) {
        if (mix <= 0.001) {
            out[0] = inL
            out[1] = inR
            return
        }

        val input = (inL + inR) * 0.02
        val damp = 0.53
        val roomFeedback = 0.75

        var outL = 0.0
        var outR = 0.0

        for (i in 0..3) {
            outL += combL[i].process(input, roomFeedback, damp)
            outR += combR[i].process(input, roomFeedback, damp)
        }

        for (i in 0..1) {
            outL = allpassL[i].process(outL)
            outR = allpassR[i].process(outR)
        }

        out[0] = inL * (1.0 - mix * 0.4) + outL * mix
        out[1] = inR * (1.0 - mix * 0.4) + outR * mix
    }

    fun reset() {
        combL.forEach { it.reset() }
        combR.forEach { it.reset() }
        allpassL.forEach { it.reset() }
        allpassR.forEach { it.reset() }
    }
}

/**
 * Lookahead-лімітер (~4 мс): знижує гучність ПЕРЕД піком, тож без спотворень і кліппінгу.
 * Мін-вікно + ковзне середнє гарантують, що вихід не перевищує стелю.
 */
class LookaheadLimiter(fs: Double) {
    private val n = (fs * 0.004).roundToInt().coerceAtLeast(8)
    private val d = n - 1
    private val cap = n + 1
    private val dl = DoubleArray(d)
    private val dr = DoubleArray(d)
    private var di = 0
    private val qv = DoubleArray(cap)
    private val qt = LongArray(cap)
    private var qHead = 0
    private var qSize = 0
    private var t = 0L
    private val mBuf = DoubleArray(n) { 1.0 }
    private var mi = 0
    private var mSum = n.toDouble()
    private var g = 1.0
    private val rel = 1.0 - exp(-1.0 / (0.08 * fs)) // реліз ~80 мс

    fun process(l: Double, r: Double, ceiling: Double, out: DoubleArray) {
        val peak = max(abs(l), abs(r))
        val req = if (peak > ceiling) ceiling / peak else 1.0

        while (qSize > 0 && qv[(qHead + qSize - 1) % cap] >= req) qSize--
        val pos = (qHead + qSize) % cap
        qv[pos] = req; qt[pos] = t; qSize++
        if (qt[qHead] <= t - n) { qHead = (qHead + 1) % cap; qSize-- }
        val m = qv[qHead]
        t++

        mSum += m - mBuf[mi]; mBuf[mi] = m; mi = (mi + 1) % n
        val box = min(1.0, mSum / n)
        g = if (box < g) box else g + (box - g) * rel

        val oL = dl[di]; val oR = dr[di]
        dl[di] = l; dr[di] = r; di = (di + 1) % d
        out[0] = oL * g
        out[1] = oR * g
    }

    fun reset() {
        dl.fill(0.0); dr.fill(0.0); di = 0
        qHead = 0; qSize = 0; t = 0L
        mBuf.fill(1.0); mi = 0; mSum = n.toDouble()
        g = 1.0
    }
}

/**
 * Ранні відбиття (7-27 мс): дають мозку відчуття кімнати й глибини,
 * тому сцена виходить з голови, а не лежить "струною" між вухами.
 */
class EarlyReflections(private val fs: Double) {
    private val size = (fs * 0.05).toInt() + 2
    private val bufL = DoubleArray(size)
    private val bufR = DoubleArray(size)
    private var w = 0
    private fun ms(v: Double) = (v / 1000.0 * fs).toInt().coerceIn(1, size - 1)
    private val tapsL = intArrayOf(ms(7.3), ms(12.1), ms(17.9), ms(24.7))
    private val tapsR = intArrayOf(ms(8.9), ms(13.7), ms(19.3), ms(27.1))
    private val gains = doubleArrayOf(0.50, 0.40, 0.30, 0.22)
    private val lpCoef = 1.0 - exp(-2.0 * PI * 8000.0 / fs) // м'який зріз верхів відбиттів
    private val hpCoef = 1.0 - exp(-2.0 * PI * 250.0 / fs)  // низи не відбиваємо: менше каламуті
    private var loL = 0.0
    private var loR = 0.0
    private var lpL = 0.0
    private var lpR = 0.0
    // Скільки центру (вокал) прибираємо з відбиттів: 0 = всі інструменти, 1 = лише боки.
    // Чим більше, тим дальші боки й тим сухіший та ближчий вокал.
    private val centerCut = 0.6

    fun process(l: Double, r: Double, amount: Double, out: DoubleArray) {
        val m = (l + r) * 0.5
        bufL[w] = l - m * centerCut
        bufR[w] = r - m * centerCut
        var eL = 0.0
        var eR = 0.0
        for (i in 0..3) {
            val iL = (w - tapsL[i] + size) % size
            val iR = (w - tapsR[i] + size) % size
            if (i % 2 == 0) {
                eL += bufL[iL] * gains[i]; eR += bufR[iR] * gains[i]
            } else { // перехресні відбиття від "стін"
                eL += bufR[iL] * gains[i]; eR += bufL[iR] * gains[i]
            }
        }
        w = (w + 1) % size
        loL += (eL - loL) * hpCoef; eL -= loL
        loR += (eR - loR) * hpCoef; eR -= loR
        lpL += (eL - lpL) * lpCoef
        lpR += (eR - lpR) * lpCoef
        out[0] = l + lpL * amount
        out[1] = r + lpR * amount
    }

    fun reset() {
        bufL.fill(0.0); bufR.fill(0.0); w = 0; lpL = 0.0; lpR = 0.0; loL = 0.0; loR = 0.0
    }
}

/**
 * Підсилює АТАКУ низів (удар бочки) тільки в момент удару, не піднімаючи бас постійно.
 * Порівнює швидку й повільну обвідні низьких частот (до ~130 Гц).
 */
class PunchEnhancer(private val fs: Double) {
    private val lpL = Biquad()
    private val lpR = Biquad()
    private fun coef(ms: Double) = 1.0 - exp(-1.0 / (ms * 0.001 * fs))
    private val fastA = coef(1.0)
    private val fastR = coef(30.0)
    private val slowA = coef(25.0)
    private val slowR = coef(250.0)
    private var fast = 0.0
    private var slow = 0.0

    init {
        lpL.configure(BandType.LOW_PASS, fs, 130.0, 0.0, 0.707)
        lpR.configure(BandType.LOW_PASS, fs, 130.0, 0.0, 0.707)
    }

    fun process(l: Double, r: Double, amount: Double, out: DoubleArray) {
        val bl = lpL.process(l)
        val br = lpR.process(r)
        val lvl = max(abs(bl), abs(br))
        fast += (lvl - fast) * (if (lvl > fast) fastA else fastR)
        slow += (lvl - slow) * (if (lvl > slow) slowA else slowR)
        val ratio = if (slow > 1e-4) (fast / slow - 1.0).coerceIn(0.0, 1.5) else 0.0
        val g = ratio * amount
        out[0] = l + bl * g
        out[1] = r + br * g
    }

    fun reset() {
        lpL.reset(); lpR.reset(); fast = 0.0; slow = 0.0
    }
}

class DspProcessor : BaseAudioProcessor() {

    @Volatile var config: DspConfig = DspConfig()

    private var applied: DspConfig? = null
    private var fs = 44100.0

    private var eq: Array<Array<Biquad>> = arrayOf(emptyArray(), emptyArray())
    private val spatialHp = arrayOf(Biquad(), Biquad())
    private val crossfeedLp = arrayOf(Biquad(), Biquad())
    private val exciterHp = arrayOf(Biquad(), Biquad())
    private val roomReverb = SmallRoomReverb()

    // Симетричний буфер для кросфіду (винесення джерел вперед без зсуву балансу)
    private var xfeedBufL = DoubleArray(128)
    private var xfeedBufR = DoubleArray(128)
    private var xfeedPtr = 0
    private var xfeedDelay = 12

    // Haas Side Delay
    private var delayBufferL = DoubleArray(1024)
    private var delayBufferR = DoubleArray(1024)
    private var delayPtr = 0
    private var delaySamples = 0

    private var preamp = 1.0
    private var limiter = LookaheadLimiter(44100.0)
    private val limOut = DoubleArray(2)
    private var early = EarlyReflections(44100.0)
    private val erOut = DoubleArray(2)

    private var rng = 88172645463325252L
    private fun rnd(): Double {
        rng = rng xor (rng shl 13)
        rng = rng xor (rng ushr 7)
        rng = rng xor (rng shl 17)
        return (rng ushr 11) * (1.0 / 9007199254740992.0)
    }
    // Сила Haas-розширення: менше значення = менше "струни", більше = ширше
    private val widthScale = 0.6
    // Ранні відбиття: скільки слайдера йде на "винесення сцени" (більше = швидше досягає повної сили)
    private val erGain = 3.0f
    // Хвіст реверба: частка слайдера (менше = менше "ванни")
    private val lateScale = 0.5
    // Удар низів (бочка): 0 = вимкнено, 0.6 = помірно, 1.0 = сильно
    private val punchAmount = 0.6
    private var punch = PunchEnhancer(44100.0)
    private val punchOut = DoubleArray(2)
    // "Повітря": high-shelf від 11 кГц, у дБ (0 = вимкнено)
    private val airDb = 2.5
    private val airShelf = arrayOf(Biquad(), Biquad())
    private var inEncoding = C.ENCODING_PCM_16BIT
    private var bytesPerSample = 2

    private fun readSample(b: ByteBuffer): Double = when (inEncoding) {
        C.ENCODING_PCM_16BIT -> b.short / 32768.0
        C.ENCODING_PCM_FLOAT -> b.float.toDouble()
        C.ENCODING_PCM_24BIT -> {
            val b0 = b.get().toInt() and 0xFF
            val b1 = b.get().toInt() and 0xFF
            val b2 = b.get().toInt()
            ((b2 shl 16) or (b1 shl 8) or b0) / 8388608.0
        }
        C.ENCODING_PCM_32BIT -> b.int / 2147483648.0
        else -> 0.0
    }

    override fun onConfigure(inputAudioFormat: AudioFormat): AudioFormat {
        val bps = when (inputAudioFormat.encoding) {
            C.ENCODING_PCM_16BIT -> 2
            C.ENCODING_PCM_24BIT -> 3
            C.ENCODING_PCM_32BIT, C.ENCODING_PCM_FLOAT -> 4
            else -> return AudioFormat.NOT_SET
        }
        if (inputAudioFormat.channelCount != 2) return AudioFormat.NOT_SET
        inEncoding = inputAudioFormat.encoding
        bytesPerSample = bps
        fs = inputAudioFormat.sampleRate.toDouble()
        limiter = LookaheadLimiter(fs)
        early = EarlyReflections(fs)
        punch = PunchEnhancer(fs)
        delaySamples = (fs * 0.012).roundToInt().coerceIn(10, 900)
        // Рівно 280 мікросекунд (симетрична затримка голови)
        xfeedDelay = (fs * 0.00028).roundToInt().coerceIn(4, 64)
        applied = null
        // Віддаємо 16-bit (наступні процесори ExoPlayer, Sonic і SilenceSkipping, приймають лише його)
        return AudioFormat(inputAudioFormat.sampleRate, 2, C.ENCODING_PCM_16BIT)
    }

    private fun refresh(c: DspConfig) {
        val active = c.bands.filter { it.enabled }
        var maxBoostDb = 0f
        for (b in active) {
            if (b.gainDb > maxBoostDb) maxBoostDb = b.gainDb
        }
        val headroomDb = if (maxBoostDb > 0f) -maxBoostDb * 0.75f - 2.0f else -2.0f
        preamp = 10.0.pow((c.preampDb + headroomDb) / 20.0)

        if (eq[0].size != active.size) {
            eq = Array(2) { Array(active.size) { Biquad() } }
        }
        for (ch in 0..1) {
            active.forEachIndexed { i, b ->
                eq[ch][i].configure(b.type, fs, b.freq.toDouble(), b.gainDb.toDouble(), b.q.toDouble())
            }
            spatialHp[ch].configure(BandType.HIGH_PASS, fs, 180.0, 0.0, 0.707)
            exciterHp[ch].configure(BandType.HIGH_PASS, fs, 4000.0, 0.0, 0.707)
            airShelf[ch].configure(BandType.HIGH_SHELF, fs, 11000.0, airDb, 0.707)
            // Фільтр Bauer кросфіду: плавний спад вище 750 Гц на протилежне вухо
            crossfeedLp[ch].configure(BandType.LOW_PASS, fs, 750.0, 0.0, 0.6)
        }
        applied = c
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val c = config
        if (c !== applied) refresh(c)

        val frames = inputBuffer.remaining() / (bytesPerSample * 2)
        val out = replaceOutputBuffer(frames * 4)

        val ceiling = 10.0.pow(c.limiterCeilingDb / 20.0)
        val sample = DoubleArray(2)
        val revOut = DoubleArray(2)
        val stereoWidth = c.stereoWidth.toDouble()

        repeat(frames) {
            sample[0] = readSample(inputBuffer)
            sample[1] = readSample(inputBuffer)

            if (c.enabled) {
                // 1. EQ & Preamp
                for (ch in 0..1) {
                    var x = sample[ch] * preamp
                    for (bq in eq[ch]) x = bq.process(x)
                    if (airDb != 0.0) x = airShelf[ch].process(x)

                    // Ламповий драйв (асиметричний tanh, 50% wet)
                    if (c.tubeDrive > 0f) {
                        val d = 1.0 + c.tubeDrive * 3.0
                        x = 0.5 * x + 0.5 * (tanh(d * x + 0.1) - tanh(0.1)) / tanh(d)
                    }
                    // Гармонічний ексайтер (верхи від 4 кГц)
                    if (c.exciterAmount > 0f) {
                        x += c.exciterAmount * tanh(4.0 * exciterHp[ch].process(x)) / 4.0
                    }
                    sample[ch] = x
                }

                // 1b. Удар низів (підсилює атаку бочки)
                if (punchAmount > 0.0) {
                    punch.process(sample[0], sample[1], punchAmount, punchOut)
                    sample[0] = punchOut[0]
                    sample[1] = punchOut[1]
                }

                // 2. Ідеально симетричний бінауральний кросфід (виносить голос уперед, баланс рівно 0:0)
                xfeedBufL[xfeedPtr] = sample[0]
                xfeedBufR[xfeedPtr] = sample[1]
                val xReadIdx = (xfeedPtr - xfeedDelay + xfeedBufL.size) % xfeedBufL.size
                val delayedL = xfeedBufL[xReadIdx]
                val delayedR = xfeedBufR[xReadIdx]
                xfeedPtr = (xfeedPtr + 1) % xfeedBufL.size

                val crossL = crossfeedLp[1].process(delayedR) * 0.35
                val crossR = crossfeedLp[0].process(delayedL) * 0.35

                sample[0] = sample[0] * 0.88 + crossL
                sample[1] = sample[1] * 0.88 + crossR

                // 3. Stereo X (дзеркальне розширення)
                if (stereoWidth > 0.02) {
                    val diffL = spatialHp[0].process(sample[0] - sample[1])
                    val diffR = spatialHp[1].process(sample[1] - sample[0])

                    delayBufferL[delayPtr] = diffL
                    delayBufferR[delayPtr] = diffR

                    val rIdx = (delayPtr - delaySamples + delayBufferL.size) % delayBufferL.size
                    val delL = delayBufferL[rIdx]
                    val delR = delayBufferR[rIdx]
                    delayPtr = (delayPtr + 1) % delayBufferL.size

                    sample[0] += (delR * 0.7 - diffR * 0.25) * stereoWidth * widthScale
                    sample[1] += (delL * 0.7 - diffL * 0.25) * stereoWidth * widthScale
                }

                // 3b. Ранні відбиття (глибина), керуються тим самим слайдером реверберації
                val erAmount = (c.reverbMix * erGain).coerceIn(0f, 1f).toDouble()
                if (erAmount > 0.0) {
                    early.process(sample[0], sample[1], erAmount, erOut)
                    sample[0] = erOut[0]
                    sample[1] = erOut[1]
                }

                // 4. Small Room Reverb (32-42% кімнати)
                roomReverb.process(sample[0], sample[1], c.reverbMix.toDouble() * lateScale, revOut)
                sample[0] = revOut[0]
                sample[1] = revOut[1]

                // 5. Lookahead-лімітер (~4 мс затримки)
                limiter.process(sample[0], sample[1], ceiling, limOut)
                sample[0] = limOut[0]
                sample[1] = limOut[1]
            }

            for (ch in 0..1) {
                // TPDF-дитеринг ±1 LSB замість голого округлення
                val v = (sample[ch].coerceIn(-1.0, 1.0) * 32767.0 + (rnd() - rnd())).roundToInt()
                out.putShort(v.coerceIn(-32768, 32767).toShort())
            }
        }
        inputBuffer.position(inputBuffer.limit())
        out.flip()
    }

    override fun onReset() {
        eq.forEach { ch -> ch.forEach { it.reset() } }
        spatialHp.forEach { it.reset() }
        crossfeedLp.forEach { it.reset() }
        exciterHp.forEach { it.reset() }
        airShelf.forEach { it.reset() }
        roomReverb.reset()
        limiter.reset()
        early.reset()
        punch.reset()
        delayBufferL.fill(0.0)
        delayBufferR.fill(0.0)
        delayPtr = 0
        xfeedBufL.fill(0.0)
        xfeedBufR.fill(0.0)
        xfeedPtr = 0
        applied = null
    }
}