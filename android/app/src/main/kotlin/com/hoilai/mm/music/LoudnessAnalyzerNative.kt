package com.hoilai.mm.music

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.tan

/**
 * ====【新增/响度归一化·Android 离线分析】====
 *
 * 职责：用 MediaExtractor + MediaCodec 把音频解码为 PCM，在原生侧完成 BS.1770 的
 * K 加权滤波与"每 100ms 子帧的通道加权均方"统计，只把统计序列回传给 Dart；
 * 门限积分（gating）在 Dart 侧统一完成，保证与 Windows 路径同一份实现、结果一致。
 *
 * 为什么把 K 加权放在原生侧：
 *   整首歌 PCM 若回传 Dart 需传输上百 MB（5 分钟 44.1k 立体声 ≈ 100MB+），
 *   MethodChannel 无法承受；原生侧一次遍历即可把回传量降到"每 100ms 一个 double"
 *   （5 分钟 ≈ 3000 个 double ≈ 24KB）。
 *
 * 关键正确性点（易错，勿轻易改动）：
 *   1) 必须处理 INFO_OUTPUT_FORMAT_CHANGED：解码器【输出】格式的采样率可能与
 *      MediaExtractor 的轨道格式不同（HE-AAC/SBR 会输出 2 倍采样率）。
 *      K 加权系数与"100ms 等于多少样本"都必须用输出格式的采样率/声道数。
 *   2) K 加权系数用与 Dart 侧 kWeightingCoeffs 完全相同的原型参数与 RBJ 公式生成，
 *      48kHz 时应还原 BS.1770 公开系数。
 *   3) 输出用 ENCODING_PCM_16BIT（默认），量化噪声约 −96dBFS，远低于 −70 LUFS 绝对门限，
 *      对结果无影响；请求 FLOAT 在部分解码器上不被支持。
 *
 * 线程约定：本对象的方法必须在【后台线程】调用（解码是重 CPU 任务）；
 * 调用方（MainActivity）负责把结果切回主线程再回调 MethodChannel.Result。
 */
object LoudnessAnalyzerNative {

    /** 每 100ms 子帧的通道加权均方序列 + 采样峰值。 */
    class Result(
        val ok: Boolean,
        val blockMeanSquares: DoubleArray?,
        val peakDbfs: Double,
        val sampleRate: Int,
        val channels: Int,
        val error: String?
    )

    /** 解码器输出格式变化的标志（与 MediaCodec 常量一致，避免版本差异）。 */
    private const val INFO_OUTPUT_FORMAT_CHANGED = -2

    /**
     * 分析音频响度。
     *
     * @param pathOrUrl 本地路径或 http(s) URL
     * @param isUrl 是否为网络地址（决定 MediaExtractor 的数据源设置方式）
     * @param maxSeconds 最长处理时长（防异常文件无限解码）
     * @param isCancelled 每个缓冲迭代检查一次，返回 true 立即放弃并释放资源
     */
    fun analyze(
        pathOrUrl: String,
        isUrl: Boolean,
        maxSeconds: Int,
        isCancelled: () -> Boolean
    ): Result {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            // ---- 1) 数据源 ----
            if (isUrl) {
                extractor.setDataSource(pathOrUrl, emptyMap<String, String>())
            } else {
                extractor.setDataSource(pathOrUrl)
            }

            // ---- 2) 选音轨（优先 audio/ ，取第一条）----
            var trackFormat: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    extractor.selectTrack(i)
                    trackFormat = f
                    break
                }
            }
            val selected = trackFormat
                ?: return Result(false, null, -120.0, 0, 0, "no_audio_track")
            val mime = selected.getString(MediaFormat.KEY_MIME)
                ?: return Result(false, null, -120.0, 0, 0, "no_mime")

            // ---- 3) 解码器 ----
            val decoder = MediaCodec.createDecoderByType(mime)
            codec = decoder
            decoder.configure(selected, null, null, 0)
            decoder.start()

            // 采样率/声道数：先用轨道格式占位，收到 OUTPUT_FORMAT_CHANGED 后以输出格式为准。
            var sampleRate = selected.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = selected.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

            var filters = KWFilter(sampleRate, channels)
            var subframeFrames = subframeSize(sampleRate)
            var subSumSquares = 0.0   // 当前子帧内的通道加权平方和
            var subFrameCount = 0     // 当前子帧已累计的帧数
            val meanSquares = ArrayList<Double>(4096)
            var peak = 0.0
            val maxFrames = maxSeconds.toLong() * sampleRate
            var processedFrames = 0L

            val bufferInfo = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false

            while (!outputDone) {
                if (isCancelled()) {
                    return Result(false, null, -120.0, sampleRate, channels, "cancelled")
                }
                if (processedFrames >= maxFrames) {
                    break // 达到处理上限
                }

                // ---- 喂入输入 ----
                if (!inputDone) {
                    val inIndex = decoder.dequeueInputBuffer(10_000)
                    if (inIndex >= 0) {
                        val inBuf = decoder.getInputBuffer(inIndex)
                        val sampleSize = if (inBuf != null) extractor.readSampleData(inBuf, 0) else -1
                        if (sampleSize < 0) {
                            decoder.queueInputBuffer(
                                inIndex, 0, 0, 0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM
                            )
                            inputDone = true
                        } else {
                            decoder.queueInputBuffer(inIndex, 0, sampleSize, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                // ---- 取出输出 ----
                val outIndex = decoder.dequeueOutputBuffer(bufferInfo, 10_000)
                if (outIndex == INFO_OUTPUT_FORMAT_CHANGED) {
                    // 输出格式可能改变采样率/声道数（SBR 常见 2 倍采样率）→ 必须重建滤波器
                    val outFormat = decoder.outputFormat
                    sampleRate = outFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = outFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    filters = KWFilter(sampleRate, channels)
                    subframeFrames = subframeSize(sampleRate)
                    subSumSquares = 0.0
                    subFrameCount = 0
                    continue
                }
                if (outIndex < 0) {
                    // TRY_AGAIN（含 -1）：继续循环（上面已做限时等待）
                    continue
                }

                val outBuf: ByteBuffer? = decoder.getOutputBuffer(outIndex)
                val isConfig = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                if (outBuf != null && bufferInfo.size > 0 && !isConfig) {
                    outBuf.position(bufferInfo.offset)
                    outBuf.limit(bufferInfo.offset + bufferInfo.size)
                    val shorts = outBuf.order(ByteOrder.nativeOrder()).asShortBuffer()
                    val sampleCount = shorts.remaining()
                    val frameCount = sampleCount / channels

                    for (f in 0 until frameCount) {
                        var frameSq = 0.0
                        for (c in 0 until channels) {
                            // 每声道独立维护滤波器状态
                            val raw = shorts.get(f * channels + c) / 32768.0
                            val a = abs(raw)
                            if (a > peak) peak = a
                            frameSq += filters.process(c, raw)
                        }
                        subSumSquares += frameSq
                        subFrameCount++
                        if (subFrameCount >= subframeFrames) {
                            // 子帧的"通道加权均方" = 子帧内平均每帧的加权平方和
                            meanSquares.add(subSumSquares / subFrameCount)
                            subSumSquares = 0.0
                            subFrameCount = 0
                        }
                    }
                    processedFrames += frameCount
                }
                decoder.releaseOutputBuffer(outIndex, false)

                if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                    outputDone = true
                }
            }

            val peakDbfs = if (peak > 0) 20 * log10(peak) else -120.0
            if (meanSquares.isEmpty()) {
                return Result(false, null, peakDbfs, sampleRate, channels, "no_data")
            }
            return Result(
                true,
                meanSquares.toDoubleArray(),
                peakDbfs,
                sampleRate,
                channels,
                null
            )
        } catch (e: Exception) {
            return Result(false, null, -120.0, 0, 0, e.message ?: "decode_failed")
        } finally {
            // 释放顺序：先 codec 后 extractor；任何异常路径都要释放，避免资源泄漏。
            try {
                codec?.stop()
            } catch (_: Exception) {
            }
            try {
                codec?.release()
            } catch (_: Exception) {
            }
            try {
                extractor.release()
            } catch (_: Exception) {
            }
        }
    }

    /** 一个 100ms 子帧的帧数（按解码器输出采样率计）。 */
    private fun subframeSize(sampleRate: Int): Int = max(1, sampleRate / 10)

    /**
     * K 加权滤波器（两级双二阶 IIR，BS.1770-4）。
     *
     * 原型参数与 Dart 侧 LoudnessAnalyzer.kWeightingCoeffs 完全一致，
     * 48kHz 时应还原标准公开系数（stage1 b=[1.53512485958697, -2.69169618940638,
     * 1.19839281085285]、a1/a2=[-1.69065929318241, 0.73248077421585]；
     * stage2 b=[1,-2,1]、a1/a2=[-1.99004745483398, 0.99007225036621]）。
     *
     * 状态按声道独立维护（每声道 8 个 double：两级各 x1,x2,y1,y2）。
     */
    private class KWFilter(sampleRate: Int, private val channels: Int) {
        private val b1 = DoubleArray(3)
        private val a1 = DoubleArray(2)
        private val b2 = DoubleArray(3)
        private val a2 = DoubleArray(2)
        private val state = Array(channels) { DoubleArray(8) }

        init {
            val fs = sampleRate.toDouble()

            // stage1：高架滤波（pre-filter）
            val f0a = 1681.974450955533
            val gainDb = 3.999843853973347
            val qa = 0.7071752369554196
            val ka = tan(PI * f0a / fs)
            val vh = 10.0.pow(gainDb / 20.0)
            val vb = vh.pow(0.4996667741545416)
            val a0 = 1.0 + ka / qa + ka * ka
            b1[0] = (vh + vb * ka / qa + ka * ka) / a0
            b1[1] = 2.0 * (ka * ka - vh) / a0
            b1[2] = (vh - vb * ka / qa + ka * ka) / a0
            a1[0] = 2.0 * (ka * ka - 1.0) / a0
            a1[1] = (1.0 - ka / qa + ka * ka) / a0

            // stage2：RLB 高通
            val f0b = 38.13547087602444
            val qb = 0.5003270373238773
            val kb = tan(PI * f0b / fs)
            val denom = 1.0 + kb / qb + kb * kb
            b2[0] = 1.0
            b2[1] = -2.0
            b2[2] = 1.0
            a2[0] = 2.0 * (kb * kb - 1.0) / denom
            a2[1] = (1.0 - kb / qb + kb * kb) / denom
        }

        /** 处理一个样本，返回 K 加权后样本的平方（累加即为该帧的能量）。 */
        fun process(channel: Int, x: Double): Double {
            val s = state[channel]
            // stage1
            val y1 = b1[0] * x + b1[1] * s[0] + b1[2] * s[1] - a1[0] * s[2] - a1[1] * s[3]
            s[1] = s[0]
            s[0] = x
            s[3] = s[2]
            s[2] = y1
            // stage2
            val y2 = b2[0] * y1 + b2[1] * s[4] + b2[2] * s[5] - a2[0] * s[6] - a2[1] * s[7]
            s[5] = s[4]
            s[4] = y1
            s[7] = s[6]
            s[6] = y2
            return y2 * y2
        }
    }
}