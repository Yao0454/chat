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
/// 以及 Opus 解码 → 增益 → 限幅 → 播放。音频回调在系统的音频线程上执行，所以这个类不在主线程上，
/// 跨线程的状态都用锁保护。
nonisolated final class VoiceEngine: @unchecked Sendable {
    /// 每编码出一帧（20ms）就调用一次，在音频线程上
    var onPacket: (@Sendable (Data) -> Void)?

    var isMuted: Bool {
        get { lock.withLock { muted } }
        set { lock.withLock { muted = newValue } }
    }

    /// 是否开启了系统的回声消除。有些设备组合下开不了，这时建议戴耳机
    private(set) var echoCancellation = false

    /// 最近的音量，0...1。界面用来画音量条
    var levels: (input: Float, output: Float) {
        lock.withLock { (inputLevel, outputLevel) }
    }

    /// 麦克风连续 2 秒采到的全是 0（不是安静，是完全没有信号）。
    /// 通常是系统的麦克风权限已经失效，App 拿到的是被静音的数据
    var micSilent: Bool {
        lock.withLock { zeroFrames >= Int(OpusCodec.sampleRate * 2) }
    }

    /// 播放端最多积压这么多采样（300ms）。网络卡顿后数据会一下子涌过来，超出的直接丢掉，免得延迟越来越大
    private static let maxQueuedFrames = AVAudioFrameCount(OpusCodec.sampleRate * 0.3)
    /// 开了回声消除后系统会压低播放音量，这里补回来；后面有限幅器，不会爆音
    private static let playbackGainDB: Float = 10

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let encoder = OpusCodec()   // 只在采集线程上用
    private let decoder = OpusCodec()   // 只在 playQueue 上用
    private let playQueue = DispatchQueue(label: "VoiceEngine.play")
    private let lock = NSLock()

    private var muted = false
    private var running = false
    private var queuedFrames: AVAudioFrameCount = 0
    private var inputLevel: Float = 0
    private var outputLevel: Float = 0
    private var zeroFrames = 0
    private var captureConverter: AVAudioConverter?
    private var pending: [Float] = []   // 攒够一帧再编码

    func start() throws {
        do {
            try startEngine(voiceProcessing: true)
        } catch {
            // 个别设备组合下回声消除仍然可能初始化失败，换一个新的引擎不带回声消除再试一次
            print("开启回声消除后启动失败，改为不带回声消除: \(error)")
            teardown()
            engine = AVAudioEngine()
            player = AVAudioPlayerNode()
            try startEngine(voiceProcessing: false)
        }
    }

    private func startEngine(voiceProcessing: Bool) throws {
        // 必须在开启回声消除之前先建好 mainMixer → 输出 的连接。
        // 反过来的话，输出端初始化会失败（-10875，kAUInitialize on outputNode），
        // 在麦克风 48kHz、扬声器 44.1kHz 的 MacBook Air 上每次都能复现
        _ = engine.mainMixerNode
        let input = engine.inputNode
        echoCancellation = false
        if voiceProcessing {
            // 系统自带的回声消除和降噪，开外放也不会把对方的声音再传回去
            do {
                try input.setVoiceProcessingEnabled(true)
                input.isVoiceProcessingAGCEnabled = true
                // 通话时尽量不压低其他 App 的声音
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
                echoCancellation = true
            } catch {
                print("回声消除开启失败，继续通话: \(error)")
            }
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: encoder.pcmFormat) else {
            throw VoiceError.noMicrophone
        }
        captureConverter = converter

        // 播放链路：player → 增益 → 限幅 → mainMixer
        let gain = AVAudioUnitEQ(numberOfBands: 0)
        gain.globalGain = Self.playbackGainDB
        let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        ))
        let format = decoder.pcmFormat
        for node in [player, gain, limiter] { engine.attach(node) }
        engine.connect(player, to: gain, format: format)
        engine.connect(gain, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.capture(buffer)
        }

        engine.prepare()
        try engine.start()
        player.play()
        lock.withLock { running = true }
    }

    /// 启动失败后清理，释放回声消除占用的设备
    private func teardown() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if echoCancellation {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }
        echoCancellation = false
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
            let level = Self.level(buffer.floatChannelData![0], count: Int(frames))
            lock.withLock {
                queuedFrames += frames
                outputLevel = max(level, outputLevel * 0.85)
            }
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
        let count = Int(resampled.frameLength)
        let level = Self.level(samples, count: count)
        let allZero = !(0..<count).contains { samples[$0] != 0 }
        pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))

        let muted = lock.withLock {
            inputLevel = self.muted ? 0 : level
            zeroFrames = allZero ? zeroFrames + count : 0
            outputLevel *= 0.85   // 对方不说话时让播放音量条慢慢落下
            return self.muted
        }
        while pending.count >= OpusCodec.frameSize {
            let frame = Array(pending[..<OpusCodec.frameSize])
            pending.removeFirst(OpusCodec.frameSize)
            // 静音时照样把采样取走，只是不发
            if !muted, let packet = encoder.encode(frame) {
                onPacket?(packet)
            }
        }
    }

    /// 均方根音量换算成 0...1：-50 dB 以下算 0，0 dB 算 1
    private static func level(_ samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let rms = (sum / Float(count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-6))
        return min(max((db + 50) / 50, 0), 1)
    }
}
