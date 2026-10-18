//  AudioDecoder.swift
//  MetalPlayer 重建工程 —— Phase 1 音频解码
//
//  链路：AVPacket → avcodec → AVFrame(任意采样格式) → libswresample → 平面 Float32 立体声
//
//  为什么统一输出「平面 Float32 / 48kHz / 立体声」：
//    AVAudioPCMBuffer 的 standardFormat 就是 deinterleaved Float32，
//    swr 直接产出 FLTP 就能一次 memcpy 进 PCM buffer，不必在 Swift 侧再做一次重排。
//    采样率不一致时交给 AVAudioEngine 的 mainMixer 做转换（它做过重采样优化）。
//
//  注意：本文件只被音频解码线程调用，内部无锁。

import Foundation

/// 一块已重采样好的 PCM（平面 Float32）。
///
/// 刻意放在 `#if USE_FFMPEG` **之外**：AudioOutput 只吃这个值类型，
/// 不依赖 FFmpeg —— 关掉开关时音频输出层仍然能独立编译。
struct PCMChunk {
    /// 每个声道一个平面。planes.count == 声道数。
    let planes: [[Float]]
    /// 该块第一个采样的媒体时间（秒）。
    let pts: Double
    let sampleRate: Int

    var channels: Int { planes.count }
    var frameCount: Int { planes.first?.count ?? 0 }
    var duration: Double {
        sampleRate > 0 ? Double(frameCount) / Double(sampleRate) : 0
    }
    /// 该块结束的媒体时间。
    var endPTS: Double { pts + duration }
}

#if USE_FFMPEG

import CFFmpeg

final class AudioDecoder {

    let timeBase: AVRational
    let outSampleRate: Int
    let outChannels: Int
    private(set) var codecName = "?"

    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var scratch: UnsafeMutablePointer<AVPacket>?

    private var swr: OpaquePointer?
    /// 用来判断输入参数是否变了（变了就重建 swr）。
    private var swrInputKey: String = ""

    init(parameters: UnsafeMutablePointer<AVCodecParameters>,
         timeBase: AVRational,
         outSampleRate: Int = 48_000,
         outChannels: Int = 2) throws {
        FFmpegSupport.ensureReady()
        self.timeBase = timeBase
        self.outSampleRate = outSampleRate
        self.outChannels = outChannels

        guard let decoder = avcodec_find_decoder(parameters.pointee.codec_id) else {
            throw FFmpegFailure(stage: "avcodec_find_decoder(audio)", code: -1)
        }
        codecName = FFmpegSupport.codecName(parameters.pointee.codec_id)

        guard let ctx = avcodec_alloc_context3(decoder) else {
            throw FFmpegFailure(stage: "avcodec_alloc_context3(audio)", code: -1)
        }
        codecCtx = ctx

        try FFmpegSupport.check(avcodec_parameters_to_context(ctx, parameters),
                                "avcodec_parameters_to_context(audio)")
        ctx.pointee.thread_count = 0
        ctx.pointee.pkt_timebase = timeBase

        try FFmpegSupport.check(avcodec_open2(ctx, decoder, nil), "avcodec_open2(audio)")

        frame = av_frame_alloc()
        scratch = av_packet_alloc()
        guard frame != nil, scratch != nil else {
            throw FFmpegFailure(stage: "av_frame_alloc/av_packet_alloc(audio)", code: -1)
        }
    }

    deinit {
        if swr != nil { swr_free(&swr) }
        if frame != nil { av_frame_free(&frame) }
        if scratch != nil { av_packet_free(&scratch) }
        if codecCtx != nil { avcodec_free_context(&codecCtx) }
    }

    func reset() {
        guard let ctx = codecCtx else { return }
        avcodec_flush_buffers(ctx)
        if swr != nil {
            // 冲刷重采样器的内部历史，否则 seek 之后会带一点上一段的拖尾
            swr_close(swr)
            _ = swr_init(swr)
        }
    }

    // MARK: - 解码

    /// 送包，取回重采样后的 PCM 块。`packet == nil` 表示冲刷。
    func decode(packet: UnsafeMutablePointer<AVPacket>?) -> [PCMChunk] {
        guard let ctx = codecCtx, let fr = frame, let sc = scratch else { return [] }

        if let p = packet, p != sc {
            av_packet_unref(sc)
            if av_packet_ref(sc, p) < 0 { return [] }
        } else {
            av_packet_unref(sc)
        }

        let sendRC = avcodec_send_packet(ctx, sc)
        av_packet_unref(sc)
        if sendRC < 0 { return [] }

        var out: [PCMChunk] = []
        while true {
            let rc = avcodec_receive_frame(ctx, fr)
            if rc < 0 { break }
            if let chunk = convert(fr) { out.append(chunk) }
            av_frame_unref(fr)
        }
        return out
    }

    // MARK: - AVFrame → PCMChunk

    private func convert(_ fr: UnsafeMutablePointer<AVFrame>) -> PCMChunk? {
        let inSamples = Int(fr.pointee.nb_samples)
        let inRate = Int(fr.pointee.sample_rate)
        let inChannels = Int(fr.pointee.ch_layout.nb_channels)
        guard inSamples > 0, inRate > 0, inChannels > 0 else { return nil }

        let inFormat = AVSampleFormat(rawValue: fr.pointee.format)
        guard ensureSwr(format: inFormat,
                        rate: inRate,
                        channels: inChannels,
                        layout: fr.pointee.ch_layout) else { return nil }
        guard let resampler = swr else { return nil }

        let maxOut = Int(swr_get_out_samples(resampler, Int32(inSamples)))
        guard maxOut > 0 else { return nil }

        guard let extended = fr.pointee.extended_data else { return nil }
        var inPtrs: [UnsafePointer<UInt8>?] = (0..<8).map { i in
            extended[i].map { UnsafePointer($0) }
        }

        var flat = [Float](repeating: 0, count: maxOut * outChannels)
        let bytesPerPlane = maxOut * MemoryLayout<Float>.size

        let produced: Int32 = flat.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return 0 }
            let raw = UnsafeMutableRawPointer(base)
            var outPtrs: [UnsafeMutablePointer<UInt8>?] = (0..<outChannels).map { ch in
                raw.advanced(by: ch * bytesPerPlane).assumingMemoryBound(to: UInt8.self)
            }
            return swr_convert(resampler, &outPtrs, Int32(maxOut), &inPtrs, Int32(inSamples))
        }
        guard produced > 0 else { return nil }
        let n = Int(produced)

        var planes: [[Float]] = []
        planes.reserveCapacity(outChannels)
        for ch in 0..<outChannels {
            let start = ch * maxOut
            planes.append(Array(flat[start..<(start + n)]))
        }

        let rawTS = fr.pointee.pts != Int64.min ? fr.pointee.pts
                                                 : fr.pointee.best_effort_timestamp
        let pts = FFmpegSupport.seconds(rawTS == Int64.min ? 0 : rawTS, timeBase)
        return PCMChunk(planes: planes, pts: pts, sampleRate: outSampleRate)
    }

    private func ensureSwr(format: AVSampleFormat,
                           rate: Int,
                           channels: Int,
                           layout: AVChannelLayout) -> Bool {
        let key = "\(format.rawValue)/\(rate)/\(channels)"
        if swr != nil, swrInputKey == key { return true }
        if swr != nil { swr_free(&swr) }

        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, Int32(outChannels))

        var inLayout = layout
        // 有些容器不给声道布局（nb_channels 有值但 order 是 UNSPEC），
        // 这时让 FFmpeg 按声道数补一个默认布局，否则 swr_init 会失败。
        if inLayout.order == AV_CHANNEL_ORDER_UNSPEC {
            var fallback = AVChannelLayout()
            av_channel_layout_default(&fallback, Int32(channels))
            inLayout = fallback
        }

        var created: OpaquePointer?
        let rc = swr_alloc_set_opts2(&created,
                                     &outLayout, AV_SAMPLE_FMT_FLTP, Int32(outSampleRate),
                                     &inLayout, format, Int32(rate),
                                     0, nil)
        guard rc >= 0, let ctx = created else { return false }
        guard swr_init(ctx) >= 0 else {
            var p: OpaquePointer? = ctx
            swr_free(&p)
            return false
        }
        swr = ctx
        swrInputKey = key
        return true
    }
}

#endif
