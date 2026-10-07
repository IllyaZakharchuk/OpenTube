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
                nb2 = a * ((a + 1) - (a - 1) * cw - s)
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

        val input = (inL + inR) * 0.015
        val damp = 0.53
        val roomFeedback = 0.74

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

        out[0] = inL * (1.0 - mix * 0.45) + outL * mix
        out[1] = inR * (1.0 - mix * 0.45) + outR * mix
    }

    fun reset() {
        combL.forEach { it.reset() }
        combR.forEach { it.reset() }
        allpassL.forEach { it.reset() }
        allpassR.forEach { it.reset() }
    }
}

class DspProcessor : BaseAudioProcessor() {

    @Volatile var config: DspConfig = DspConfig()

    private var applied: DspConfig? = null
    private var fs = 44100.0

    private var eq: Array<Array<Biquad>> = arrayOf(emptyArray(), emptyArray())
    private val spatialHp = arrayOf(Biquad(), Biquad())
    private val vocalBandpass = arrayOf(Biquad(), Biquad())
    private val roomReverb = SmallRoomReverb()

    // Haas Side Delay
    private var delayBufferL = DoubleArray(1024)
    private var delayBufferR = DoubleArray(1024)
    private var delayPtr = 0
    private var delaySamples = 0

    // Center Stage Decoupler Buffer (для виносу вокалу з голови)
    private var vocalDelayBuf = DoubleArray(256)
    private var vocalDelayPtr = 0
    private var vocalDelaySamples = 0

    private var preamp = 1.0

    override fun onConfigure(inputAudioFormat: AudioFormat): AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT ||
            inputAudioFormat.channelCount != 2
        ) return AudioFormat.NOT_SET
        fs = inputAudioFormat.sampleRate.toDouble()
        delaySamples = (fs * 0.012).roundToInt().coerceIn(10, 900)
        // 1.8 мс затримка для моно-центру (психоакустичний винос джерела вперед)
        vocalDelaySamples = (fs * 0.0018).roundToInt().coerceIn(10, 200)
        applied = null
        return inputAudioFormat
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
            // Виділення діапазону людського голосу (300 Hz - 4000 Hz)
            vocalBandpass[ch].configure(BandType.PEAK, fs, 1200.0, 0.0, 0.5)
        }
        applied = c
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val c = config
        if (c !== applied) refresh(c)

        val frames = inputBuffer.remaining() / 4
        val out = replaceOutputBuffer(frames * 4)

        val ceiling = 10.0.pow(c.limiterCeilingDb / 20.0)
        val sample = DoubleArray(2)
        val revOut = DoubleArray(2)
        val stereoWidth = c.stereoWidth.toDouble()

        repeat(frames) {
            sample[0] = inputBuffer.short / 32768.0
            sample[1] = inputBuffer.short / 32768.0

            if (c.enabled) {
                // 1. EQ & Preamp
                for (ch in 0..1) {
                    var x = sample[ch] * preamp
                    for (bq in eq[ch]) x = bq.process(x)
                    sample[ch] = x
                }

                // 2. Center Stage Decoupler (Винос голосу з голови вперед)
                // Виділяємо чистий моно-центр
                val center = (sample[0] + sample[1]) * 0.5
                vocalDelayBuf[vocalDelayPtr] = center
                val vReadIdx = (vocalDelayPtr - vocalDelaySamples + vocalDelayBuf.size) % vocalDelayBuf.size
                val delayedCenter = vocalDelayBuf[vReadIdx]
                vocalDelayPtr = (vocalDelayPtr + 1) % vocalDelayBuf.size

                // Підмішуємо злегка декоррельовану затримку в протифазі:
                // голос залишається по центру, але зміщується зсередини черепа у простір перед обличчям
                val vocalAir = (center - delayedCenter) * 0.28
                sample[0] = sample[0] + vocalAir
                sample[1] = sample[1] - vocalAir

                // 3. Poweramp Stereo X (бічні інструменти)
                if (stereoWidth > 0.02) {
                    val diffL = spatialHp[0].process(sample[0] - sample[1])
                    val diffR = spatialHp[1].process(sample[1] - sample[0])

                    delayBufferL[delayPtr] = diffL
                    delayBufferR[delayPtr] = diffR

                    val rIdx = (delayPtr - delaySamples + delayBufferL.size) % delayBufferL.size
                    val delL = delayBufferL[rIdx]
                    val delR = delayBufferR[rIdx]
                    delayPtr = (delayPtr + 1) % delayBufferL.size

                    sample[0] += (delR * 0.75 - diffR * 0.25) * stereoWidth
                    sample[1] += (delL * 0.75 - diffL * 0.25) * stereoWidth
                }

                // 4. Small Room Reverb
                roomReverb.process(sample[0], sample[1], c.reverbMix.toDouble(), revOut)
                sample[0] = revOut[0]
                sample[1] = revOut[1]

                // 5. Soft Limiter
                for (ch in 0..1) {
                    val sVal = sample[ch]
                    sample[ch] = if (abs(sVal) > ceiling) {
                        val sign = if (sVal > 0) 1.0 else -1.0
                        val excess = abs(sVal) - ceiling
                        sign * (ceiling + (1.0 - ceiling) * tanh(excess / (1.0 - ceiling)))
                    } else {
                        sVal
                    }
                }
            }

            for (ch in 0..1) {
                val v = (sample[ch] * 32760.0).roundToInt().coerceIn(-32767, 32767)
                out.putShort(v.toShort())
            }
        }
        inputBuffer.position(inputBuffer.limit())
        out.flip()
    }

    override fun onReset() {
        eq.forEach { ch -> ch.forEach { it.reset() } }
        spatialHp.forEach { it.reset() }
        vocalBandpass.forEach { it.reset() }
        roomReverb.reset()
        delayBufferL.fill(0.0)
        delayBufferR.fill(0.0)
        delayPtr = 0
        vocalDelayBuf.fill(0.0)
        vocalDelayPtr = 0
        applied = null
    }
}