import AVFoundation

/// 来电铃声和去电回铃音。都是程序合成的，不需要音频文件，循环播放直到停止
@MainActor
final class Ringer {
    private var player: AVAudioPlayer?

    /// 来电：明亮的琶音，一组约 3 秒
    func playIncoming() { play(Self.incoming, volume: 0.9) }

    /// 去电等待对方接听：国内标准的回铃音，450Hz 响 1 秒停 4 秒
    func playRingback() { play(Self.ringback, volume: 0.5) }

    func stop() {
        player?.stop()
        player = nil
    }

    private func play(_ wav: Data, volume: Float) {
        stop()
        player = try? AVAudioPlayer(data: wav)
        player?.numberOfLoops = -1
        player?.volume = volume
        player?.play()
    }

    // MARK: - 合成

    private static let sampleRate = 44100.0

    private static let incoming: Data = {
        // E5 G#5 B5 E6 两遍，像马林巴琴，后面留 1.2 秒空白
        let notes: [Double] = [659.25, 830.61, 987.77, 1318.51]
        var samples = [Float](repeating: 0, count: Int(sampleRate * 3.0))
        for round in 0..<2 {
            for (i, freq) in notes.enumerated() {
                let start = Double(round) * 0.9 + Double(i) * 0.16
                addNote(&samples, freq: freq, at: start, length: 0.6, amplitude: 0.32)
            }
        }
        return wav(samples)
    }()

    private static let ringback: Data = {
        var samples = [Float](repeating: 0, count: Int(sampleRate * 5.0))
        let on = Int(sampleRate * 1.0)
        let fade = Int(sampleRate * 0.02)
        for i in 0..<on {
            let envelope = Float(min(1, Double(min(i, on - i)) / Double(fade)))
            samples[i] = Float(sin(2 * .pi * 450 * Double(i) / sampleRate)) * 0.3 * envelope
        }
        return wav(samples)
    }()

    /// 一个带衰减的音：基音 + 少量八度泛音，起音 5ms，然后指数衰减
    private static func addNote(_ samples: inout [Float], freq: Double, at start: Double, length: Double, amplitude: Double) {
        let first = Int(start * sampleRate)
        let count = Int(length * sampleRate)
        for i in 0..<count where first + i < samples.count {
            let t = Double(i) / sampleRate
            let attack = min(1, t / 0.005)
            let envelope = attack * exp(-t * 7)
            let tone = sin(2 * .pi * freq * t) + 0.25 * sin(4 * .pi * freq * t)
            samples[first + i] += Float(tone * envelope * amplitude)
        }
    }

    /// 单声道 16 位 PCM 的 WAV 文件
    private static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))                     // PCM，单声道
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)) // 采样率，每秒字节数
        append(UInt16(2)); append(UInt16(16))                     // 每帧字节数，位深
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        for s in samples {
            append(Int16(max(-1, min(1, s)) * Float(Int16.max)))
        }
        return data
    }
}
