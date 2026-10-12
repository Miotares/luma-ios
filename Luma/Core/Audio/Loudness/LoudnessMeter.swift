import Accelerate
import AVFoundation

/// A track's measured loudness: integrated programme loudness (LUFS) and sample peak (dBFS).
nonisolated struct LoudnessMeasurement: Sendable, Equatable {
    var lufs: Double
    var peakDB: Double
}

/// Measures integrated loudness per ITU-R BS.1770-4 / EBU R 128: K-weighting, 400 ms blocks with
/// 75 % overlap, absolute (−70 LUFS) and relative (−10 LU) gating. This is the same quantity
/// Spotify / Apple Sound Check normalize to, so tracks from different sources end up equally loud
/// to the ear — a plain peak or RMS comparison does not achieve that.
///
/// Pure, stateless and off the main actor: it decodes the whole file once, so callers run it at
/// low priority and one at a time (parallel full-file decodes have starved the audio render thread
/// here before).
nonisolated enum LoudnessMeter {
    /// `maxSeconds` stops early for a quick estimate; nil measures the whole file.
    /// Returns nil when the file can't be decoded or holds no signal above the −70 LUFS gate.
    static func measure(url: URL, maxSeconds: Double? = nil) async -> LoudnessMeasurement? {
        if let file = try? AVAudioFile(forReading: url) {
            return measure(file: file, maxSeconds: maxSeconds)
        }
        // Containers AVAudioFile rejects (Opus/Ogg) — same fallback the playback decoder uses.
        return await measureWithAssetReader(url: url, maxSeconds: maxSeconds)
    }

    // MARK: - Sources

    private static func measure(file: AVAudioFile, maxSeconds: Double?) -> LoudnessMeasurement? {
        let format = file.processingFormat
        guard format.sampleRate > 0, format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else { return nil }
        var accumulator = Accumulator(sampleRate: format.sampleRate, channels: Int(format.channelCount))
        let frameLimit = maxSeconds.map { AVAudioFramePosition($0 * format.sampleRate) }

        while file.framePosition < file.length {
            if Task.isCancelled { return nil }
            if let frameLimit, file.framePosition >= frameLimit { break }
            do { try file.read(into: buffer) } catch { break }
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            accumulator.add(channels: channels, frames: Int(buffer.frameLength))
        }
        return accumulator.result()
    }

    private static func measureWithAssetReader(url: URL, maxSeconds: Double?) async -> LoudnessMeasurement? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var accumulator: Accumulator?
        var format: AVAudioFormat?
        var framesRead = 0.0
        while reader.status == .reading {
            if Task.isCancelled { reader.cancelReading(); return nil }
            guard let sample = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sample) }
            guard let description = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { continue }
            if format == nil {
                format = AVAudioFormat(streamDescription: asbd)
                if let format {
                    accumulator = Accumulator(sampleRate: format.sampleRate, channels: Int(format.channelCount))
                }
            }
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard let format, frames > 0,
                  let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { continue }
            pcm.frameLength = frames
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList
            ) == noErr, let channels = pcm.floatChannelData else { continue }
            accumulator?.add(channels: channels, frames: Int(frames))
            framesRead += Double(frames)
            if let maxSeconds, framesRead >= maxSeconds * format.sampleRate {
                reader.cancelReading()
                break
            }
        }
        return accumulator?.result()
    }

    // MARK: - BS.1770 accumulator

    private struct Accumulator {
        private let channels: Int
        /// 100 ms hop; four consecutive hops form one 400 ms gating block (75 % overlap).
        private let hopFrames: Int
        private var filters: [vDSP.Biquad<Double>]
        private var scratch: [Double]
        private var hopFill = 0
        private var hopEnergy = 0.0          // Σ over channels of Σ x² within the current hop
        private var hopEnergies: [Double] = []
        private var peak: Float = 0

        init(sampleRate: Double, channels: Int) {
            self.channels = channels
            hopFrames = max(1, Int((sampleRate * 0.1).rounded()))
            let coefficients = Self.kWeighting(sampleRate: sampleRate)
            filters = (0..<channels).compactMap { _ in
                vDSP.Biquad(coefficients: coefficients, channelCount: 1, sectionCount: 2, ofType: Double.self)
            }
            scratch = []
        }

        mutating func add(channels data: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int) {
            guard frames > 0, filters.count == channels else { return }
            if scratch.count < frames { scratch = [Double](repeating: 0, count: frames) }
            // Filter each channel for the whole chunk first (the biquads carry their own state),
            // keeping the weighted signal per channel so hops can be summed across channels.
            var weighted: [[Double]] = []
            weighted.reserveCapacity(channels)
            for ch in 0..<channels {
                var channelPeak: Float = 0
                vDSP_maxmgv(data[ch], 1, &channelPeak, vDSP_Length(frames))
                peak = max(peak, channelPeak)
                scratch.withUnsafeMutableBufferPointer { out in
                    vDSP_vspdp(data[ch], 1, out.baseAddress!, 1, vDSP_Length(frames))
                }
                weighted.append(filters[ch].apply(input: Array(scratch[0..<frames])))
            }

            var offset = 0
            while offset < frames {
                let take = min(hopFrames - hopFill, frames - offset)
                for ch in 0..<channels {
                    var sum = 0.0
                    weighted[ch].withUnsafeBufferPointer { p in
                        vDSP_svesqD(p.baseAddress! + offset, 1, &sum, vDSP_Length(take))
                    }
                    hopEnergy += sum
                }
                hopFill += take
                offset += take
                if hopFill == hopFrames {
                    hopEnergies.append(hopEnergy)
                    hopEnergy = 0
                    hopFill = 0
                }
            }
        }

        func result() -> LoudnessMeasurement? {
            guard hopEnergies.count >= 4, peak > 0 else { return nil }
            let blockFrames = Double(hopFrames * 4)
            // A mono file is played on both speakers, i.e. it sounds like the same signal in two
            // channels (+3 dB) — weight it that way so mono and stereo tracks match by ear.
            let channelScale = channels == 1 ? 2.0 : 1.0
            var blocks: [Double] = []
            blocks.reserveCapacity(hopEnergies.count - 3)
            var window = hopEnergies[0] + hopEnergies[1] + hopEnergies[2] + hopEnergies[3]
            blocks.append(window / blockFrames * channelScale)
            for i in 4..<hopEnergies.count {
                window += hopEnergies[i] - hopEnergies[i - 4]
                blocks.append(max(0, window) / blockFrames * channelScale)
            }

            func loudness(_ meanSquare: Double) -> Double { -0.691 + 10 * log10(meanSquare) }
            let absoluteGate = pow(10, (-70 + 0.691) / 10)
            let aboveAbsolute = blocks.filter { $0 > absoluteGate }
            guard !aboveAbsolute.isEmpty else { return nil }
            let relativeGate = aboveAbsolute.reduce(0, +) / Double(aboveAbsolute.count) * pow(10, -10.0 / 10)
            let gated = aboveAbsolute.filter { $0 > relativeGate }
            guard !gated.isEmpty else { return nil }
            let lufs = loudness(gated.reduce(0, +) / Double(gated.count))
            guard lufs.isFinite else { return nil }
            return LoudnessMeasurement(lufs: lufs, peakDB: 20 * log10(Double(peak)))
        }

        /// The two K-weighting biquads (high shelf, then high-pass) as [b0, b1, b2, a1, a2] each,
        /// derived for the actual sample rate (the standard only tabulates 48 kHz).
        private static func kWeighting(sampleRate fs: Double) -> [Double] {
            // Stage 1: high-shelf, +4 dB above ~1.7 kHz (head acoustics).
            let f1 = 1681.974450955533, gain = 3.999843853973347, q1 = 0.7071752369554196
            let k1 = tan(.pi * f1 / fs)
            let vh = pow(10, gain / 20)
            let vb = pow(vh, 0.4996667741545416)
            let d1 = 1 + k1 / q1 + k1 * k1
            let shelf = [
                (vh + vb * k1 / q1 + k1 * k1) / d1,
                2 * (k1 * k1 - vh) / d1,
                (vh - vb * k1 / q1 + k1 * k1) / d1,
                2 * (k1 * k1 - 1) / d1,
                (1 - k1 / q1 + k1 * k1) / d1,
            ]
            // Stage 2: high-pass at ~38 Hz.
            let f2 = 38.13547087602444, q2 = 0.5003270373238773
            let k2 = tan(.pi * f2 / fs)
            let d2 = 1 + k2 / q2 + k2 * k2
            let highPass = [1, -2, 1, 2 * (k2 * k2 - 1) / d2, (1 - k2 / q2 + k2 * k2) / d2]
            return shelf + highPass
        }
    }
}
