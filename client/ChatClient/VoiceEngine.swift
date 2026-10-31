import AVFoundation

enum VoiceError: LocalizedError {
    case noMicrophone

    var errorDescription: String? {
        switch self {
        case .noMicrophone: "找不到可用的麦克风"
        }
    }
}

/// Opus 编解码，用系统自带的 AVAudioConverter。
/// 每帧 20ms（48kHz 单声道 960 个采样），24 kbps 下编码后大约 70–90 字节。
nonisolated final class OpusCodec {
    static let sampleRate: Double = 48000
    static let frameSize = 960

    let pcmFormat: AVAudioFormat
    private let opusFormat: AVAudioFormat
    private let encoder: AVAudioConverter
    private let decoder: AVAudioConverter

    init() {
        pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false
        )!
        var desc = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(Self.frameSize), mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0
        )
        opusFormat = AVAudioFormat(streamDescription: &desc)!
        encoder = AVAudioConverter(from: pcmFormat, to: opusFormat)!
        encoder.bitRate = 24000
        decoder = AVAudioConverter(from: opusFormat, to: pcmFormat)!
    }

    /// 输入正好一帧（960 个采样）
    func encode(_ samples: [Float]) -> Data? {
        guard let input = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

        let output = AVAudioCompressedBuffer(
            format: opusFormat, packetCapacity: 1, maximumPacketSize: encoder.maximumOutputPacketSize
        )
        guard convert(encoder, from: input, to: output), output.packetCount > 0,
              let size = output.packetDescriptions?[0].mDataByteSize else { return nil }
        return Data(bytes: output.data, count: Int(size))
    }

    func decode(_ packet: Data) -> AVAudioPCMBuffer? {
        guard !packet.isEmpty else { return nil }
        let input = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        input.packetDescriptions![0] = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count)
        )
        input.packetCount = 1
        input.byteLength = UInt32(packet.count)

        guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(Self.frameSize)),
              convert(decoder, from: input, to: output), output.frameLength > 0 else { return nil }
        return output
    }
}

/// 把一个输入缓冲交给转换器，转换器内部会保留状态（重采样、编解码都需要）
nonisolated func convert(_ converter: AVAudioConverter, from input: AVAudioBuffer, to output: AVAudioBuffer) -> Bool {
    let feed = OneShotInput(input)
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, status in feed.next(status) }
    return status != .error && error == nil
}

/// 转换器的输入回调：第一次给数据，之后告诉它"暂时没有了"
private nonisolated final class OneShotInput: @unchecked Sendable {
    private var buffer: AVAudioBuffer?

    init(_ buffer: AVAudioBuffer) { self.buffer = buffer }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}

/// 通话的音频部分：麦克风 → 回声消除 → 重采样到 48kHz → Opus 编码，
/// 以及 Opus 解码 → 播放。音频回调在系统的音频线程上执行，所以这个类不在主线程上，
/// 跨线程的状态都用锁保护。
nonisolated final class VoiceEngine: @unchecked Sendable {
    /// 每编码出一帧（20ms）就调用一次，在音频线程上
    var onPacket: (@Sendable (Data) -> Void)?

    var isMuted: Bool {
        get { lock.withLock { muted } }
        set { lock.withLock { muted = newValue } }
    }

    /// 播放端最多积压这么多采样（300ms）。网络卡顿后数据会一下子涌过来，超出的直接丢掉，免得延迟越来越大
    private static let maxQueuedFrames = AVAudioFrameCount(OpusCodec.sampleRate * 0.3)

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let encoder = OpusCodec()   // 只在采集线程上用
    private let decoder = OpusCodec()   // 只在 playQueue 上用
    private let playQueue = DispatchQueue(label: "VoiceEngine.play")
    private let lock = NSLock()

    private var muted = false
    private var running = false
    private var queuedFrames: AVAudioFrameCount = 0
    private var captureConverter: AVAudioConverter?
    private var pending: [Float] = []   // 攒够一帧再编码

    func start() throws {
        let input = engine.inputNode
        // 系统自带的回声消除和降噪，开外放也不会把对方的声音再传回去
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            print("回声消除开启失败，继续通话: \(error)")
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: encoder.pcmFormat) else {
            throw VoiceError.noMicrophone
        }
        captureConverter = converter

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: decoder.pcmFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.capture(buffer)
        }

        engine.prepare()
        try engine.start()
        player.play()
        lock.withLock { running = true }
    }

    func stop() {
        lock.withLock { running = false }
        playQueue.sync {}   // 等正在排队的播放任务做完
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
    }

    /// 收到对方的一帧语音
    func play(_ packet: Data) {
        playQueue.async { [self] in
            let ok = lock.withLock { running && queuedFrames < Self.maxQueuedFrames }
            guard ok, let buffer = decoder.decode(packet) else { return }
            let frames = buffer.frameLength
            lock.withLock { queuedFrames += frames }
            player.scheduleBuffer(buffer) { [weak self] in
                guard let self else { return }
                self.lock.withLock { self.queuedFrames -= frames }
            }
        }
    }

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard let converter = captureConverter else { return }
        let ratio = OpusCodec.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let resampled = AVAudioPCMBuffer(pcmFormat: encoder.pcmFormat, frameCapacity: capacity),
              convert(converter, from: buffer, to: resampled),
              let samples = resampled.floatChannelData?[0] else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(resampled.frameLength)))

        let muted = isMuted
        while pending.count >= OpusCodec.frameSize {
            let frame = Array(pending[..<OpusCodec.frameSize])
            pending.removeFirst(OpusCodec.frameSize)
            // 静音时照样把采样取走，只是不发
            if !muted, let packet = encoder.encode(frame) {
                onPacket?(packet)
            }
        }
    }
}
