import AVFoundation
import AVFAudio

/// A track prepared for an AVAudioPlayerNode. Fast path is an AVAudioFile (the node reads it
/// lazily — handles FLAC/ALAC/MP3/AAC/WAV/AIFF). Fallback is fully-decoded PCM buffers for
/// containers AVAudioFile rejects (notably Opus/Ogg), so every importable format stays
/// playable on the new engine.
enum DecodedTrack {
    case file(AVAudioFile)
    case buffers(_ buffers: [AVAudioPCMBuffer], format: AVAudioFormat, totalFrames: AVAudioFramePosition)

    /// The native processing format of the source — the player node's input must be
    /// connected with this so the graph mixer resamples it to the output rate.
    var processingFormat: AVAudioFormat {
        switch self {
        case .file(let f):            return f.processingFormat
        case .buffers(_, let fmt, _): return fmt
        }
    }

    var lengthFrames: AVAudioFramePosition {
        switch self {
        case .file(let f):              return f.length
        case .buffers(_, _, let total): return total
        }
    }

    var sampleRate: Double { processingFormat.sampleRate }
}

enum TrackDecoder {
    /// Opens a track for the engine. Returns nil for a missing/undecodable file.
    static func open(url: URL) async -> DecodedTrack? {
        // Fast path — most formats. AVAudioFile reads frames on demand during playback.
        if let file = try? AVAudioFile(forReading: url) {
            return .file(file)
        }
        // Fallback for what AVAudioFile won't open (Opus/Ogg, exotic containers).
        return await decodeToBuffers(url: url)
    }

    /// AVAssetReader fallback: decode the entire track up front to non-interleaved float PCM.
    private static func decodeToBuffers(url: URL) async -> DecodedTrack? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }

        // Non-interleaved float so the buffers match a standard AVAudioFormat directly.
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

        var buffers: [AVAudioPCMBuffer] = []
        var format: AVAudioFormat?
        var total: AVAudioFramePosition = 0

        while reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sample) }
            guard let desc = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { continue }
            if format == nil { format = AVAudioFormat(streamDescription: asbd) }
            guard let fmt = format, let pcm = pcmBuffer(from: sample, format: fmt) else { continue }
            buffers.append(pcm)
            total += AVAudioFramePosition(pcm.frameLength)
        }

        guard reader.status == .completed, let fmt = format, !buffers.isEmpty else {
            reader.cancelReading()
            return nil
        }
        return .buffers(buffers, format: fmt, totalFrames: total)
    }

    private static func pcmBuffer(from sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList
        )
        return status == noErr ? pcm : nil
    }
}
