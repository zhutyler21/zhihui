import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

enum RecordingMode: String, CaseIterable, Identifiable {
    case microphone = "麦克风", system = "系统声音", combined = "麦克风 + 系统"
    var id: String { rawValue }
    var needsMicrophone: Bool { self != .system }
    var needsSystem: Bool { self != .microphone }
}
struct AudioChunk {
    let id: String; let path: String; let startSeconds: Double; let durationSeconds: Double
}
private enum CaptureTrack: String { case microphone, system }
private final class ConverterState {
    var format: AVAudioFormat; var converter: AVAudioConverter; var nextFrame: Int?; var lastInputEnd: Double = 0
    init?(format: AVAudioFormat, output: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: format, to: output) else { return nil }
        self.format = format; self.converter = converter; converter.primeMethod = .none
    }
}

/// Inputs contribute once to a 16 kHz clock. A 2-second holdback allows unequal callback latency.
/// Very late samples become timestamped recovery WAVs; published audio never loses an input prefix.
final class TimelineMixer {
    private(set) var samples: [Float] = []
    private(set) var emittedFrames = 0
    func add(_ input: [Float], start: Int, gain: Float = 0.5) -> (samples: [Float], start: Int)? {
        let start = max(0, start)
        let lateCount = min(input.count, max(0, emittedFrames - start))
        let remaining = input.count - lateCount
        if remaining > 0 {
            let relative = max(0, start + lateCount - emittedFrames), needed = relative + remaining
            if samples.count < needed { samples.append(contentsOf: repeatElement(0, count: needed - samples.count)) }
            for index in 0..<remaining { samples[relative + index] += input[lateCount + index] * gain }
        }
        if lateCount > 0 { return (Array(input.prefix(lateCount)).map { $0 * gain }, start) }
        return nil
    }
    func commit(_ count: Int) { samples.removeFirst(count); emittedFrames += count }
    func ensureEnd(_ frame: Int) {
        let needed = max(0, frame - emittedFrames)
        if samples.count < needed { samples.append(contentsOf: repeatElement(0, count: needed - samples.count)) }
    }
}

/// Capture, conversion, clock alignment and publication run on a single serial queue.
/// Hardware lifecycle is controlled by the main actor; there are no TCC edits or UI automation.
final class AudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.local.zhihui.audio", qos: .userInitiated)
    private var engine: AVAudioEngine?; private var stream: SCStream?; private var timer: DispatchSourceTimer?
    private var converters: [CaptureTrack: ConverterState] = [:]
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var singleSamples: [Float] = []; private var singleEmittedFrames = 0; private var mixer = TimelineMixer()
    private var active = false; private var mixed = false; private var anchorSeconds: Double = 0
    private var prepared = false; private var timelineGain: Float = 0.5
    private var folder: URL?; private var callback: ((AudioChunk) -> Void)?; private var failure: ((String) -> Void)?
    private var publishedChunks: [AudioChunk] = []; private var tapInstalled = false
    private var lifecycleSession: UUID?
    let chunkFrames = 160000
    private var liveTranslation = false
    private static func hostSeconds() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    @MainActor func start(mode: RecordingMode, directory: URL, liveTranslation: Bool = false, onChunk: @escaping (AudioChunk) -> Void, onError: @escaping (String) -> Void) async throws {
        let lifecycleID = UUID()
        queue.sync {
            lifecycleSession = lifecycleID; publishedChunks = []; singleSamples = []; converters = [:]; mixer = TimelineMixer()
            active = false; prepared = false; folder = nil; callback = onChunk; failure = onError
            self.liveTranslation = liveTranslation
        }
        // Resolve both permissions before starting either source in combined mode.
        if mode.needsMicrophone {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            let allowed = status == .notDetermined ? await AVCaptureDevice.requestAccess(for: .audio) : status == .authorized
            guard allowed else { throw APIError(message: "麦克风未获授权。请在系统设置 → 隐私与安全性 → 麦克风中允许知会。") }
        }
        var display: SCDisplay?
        if mode.needsSystem {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                display = content.displays.first
                guard display != nil else { throw APIError(message: "没有可用的显示器") }
            } catch { throw APIError(message: "系统声音录制未启动：\(error.localizedDescription)。请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许知会，再重试。") }
        }
        guard queue.sync(execute: { lifecycleSession == lifecycleID }) else { throw CancellationError() }
        let recordingFolder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: recordingFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        queue.sync {
            singleSamples = []; singleEmittedFrames = 0; mixer = TimelineMixer(); converters = [:]
            folder = recordingFolder; callback = onChunk; failure = onError; active = true
            mixed = mode.needsSystem; timelineGain = mode == .combined ? 0.5 : 1
            prepared = true; anchorSeconds = Self.hostSeconds(); publishedChunks = []
        }
        do {
            if mode.needsMicrophone {
                let audioEngine = AVAudioEngine(); let input = audioEngine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { throw APIError(message: "没有可用的麦克风，请检查音频输入设备。") }
                input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
                    guard let self else { return }
                    guard let copy = Self.copy(buffer) else { self.failure?("麦克风音频缓存不足，录音已停止。"); return }
                    let timestamp = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : Self.hostSeconds() - Double(buffer.frameLength) / buffer.format.sampleRate
                    self.queue.async { self.consume(copy, track: .microphone, timestamp: timestamp) }
                }
                tapInstalled = true; engine = audioEngine; audioEngine.prepare(); try audioEngine.start()
            }
            if let display {
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let config = SCStreamConfiguration(); config.capturesAudio = true; config.sampleRate = 48000; config.channelCount = 2
                config.excludesCurrentProcessAudio = true
                // No screen image output is registered or persisted.
                config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                config.queueDepth = 3; config.showsCursor = false
                let capture = SCStream(filter: filter, configuration: config, delegate: self)
                try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                stream = capture; try await capture.startCapture()
            }
            if mode.needsSystem {
                let clock = DispatchSource.makeTimerSource(queue: queue)
                clock.schedule(deadline: .now() + 1, repeating: .milliseconds(500))
                clock.setEventHandler { [weak self] in
                    guard let self, self.active else { return }
                    let now = Self.hostSeconds(); self.flushIdle(at: now)
                    let through = Int((now - self.anchorSeconds - 2) * 16000)
                    self.mixer.ensureEnd(through)
                    self.publishMixed(through: through, finish: false)
                }
                timer = clock; clock.resume()
            }
            guard queue.sync(execute: { lifecycleSession == lifecycleID }) else { throw CancellationError() }
        } catch {
            _ = await stop()
            if mode.needsSystem { throw APIError(message: "声音录制未启动：\(error.localizedDescription)。请检查麦克风及屏幕与系统音频录制权限。") }
            throw error
        }
    }
    @MainActor func stop() async -> [AudioChunk] {
        queue.sync { lifecycleSession = nil }
        let stopTime = Self.hostSeconds()
        timer?.cancel(); timer = nil
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine?.stop(); engine = nil
        if let stream { try? await stream.stopCapture() }; stream = nil
        return await withCheckedContinuation { continuation in
            queue.async {
                if self.prepared {
                    for track in [CaptureTrack.microphone, .system] { self.drain(track) }
                    if self.mixed {
                        self.mixer.ensureEnd(max(0, Int((stopTime - self.anchorSeconds) * 16000)))
                        self.publishMixed(through: Int.max, finish: true)
                    } else if !self.singleSamples.isEmpty { self.publishSingle(count: self.singleSamples.count) }
                }
                self.active = false; self.prepared = false; self.converters = [:]
                continuation.resume(returning: self.publishedChunks)
            }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { failure?("系统声音录制中断：\(error.localizedDescription)。已有音频已保留。") }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        do {
            try sampleBuffer.withAudioBufferList { list, _ in
                guard let description = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return }
                var asbd = description
                guard let format = AVAudioFormat(streamDescription: &asbd), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples)) else { failure?("无法读取系统声音格式。"); return }
                buffer.frameLength = AVAudioFrameCount(sampleBuffer.numSamples)
                let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                for index in 0..<min(destination.count, list.count) {
                    guard let from = list[index].mData, let to = destination[index].mData else { continue }
                    memcpy(to, from, min(Int(list[index].mDataByteSize), Int(destination[index].mDataByteSize)))
                }
                let timestamp = sampleBuffer.presentationTimeStamp.seconds
                consume(buffer, track: .system, timestamp: timestamp.isFinite ? timestamp : Self.hostSeconds() - Double(buffer.frameLength) / format.sampleRate)
            }
        } catch { failure?("系统声音数据读取失败：\(error.localizedDescription)") }
    }
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let result = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        result.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList), destination = UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard let from = source[index].mData, let to = destination[index].mData else { continue }
            memcpy(to, from, Int(source[index].mDataByteSize))
        }
        return result
    }
    private func consume(_ buffer: AVAudioPCMBuffer, track: CaptureTrack, timestamp: Double) {
        guard active, buffer.frameLength > 0 else { return }
        if converters[track]?.format != buffer.format {
            drain(track); converters[track] = ConverterState(format: buffer.format, output: outputFormat)
        }
        guard let state = converters[track] else { failure?("无法转换录音格式，已有录音已保留。"); return }
        state.lastInputEnd = timestamp + Double(buffer.frameLength) / buffer.format.sampleRate
        if mixed {
            let frame = max(0, Int(((timestamp - anchorSeconds) * 16000).rounded()))
            // Large discontinuities retain their real position. SRC rounding stays continuous.
            if state.nextFrame == nil || abs(frame - state.nextFrame!) > 1600 { state.nextFrame = frame }
        }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate)) + 512
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { failure?("音频转换缓存不足。"); return }
        var supplied = false; var error: NSError?
        let status = state.converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true; inputStatus.pointee = .haveData; return buffer
        }
        if status == .error { failure?("录音格式转换失败：\(error?.localizedDescription ?? "未知错误")"); return }
        append(output, state: state)
    }
    private func drain(_ track: CaptureTrack) {
        guard let state = converters[track] else { return }
        for _ in 0..<4 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1024) else { return }
            var error: NSError?
            let status = state.converter.convert(to: output, error: &error) { _, value in value.pointee = .endOfStream; return nil }
            append(output, state: state)
            if output.frameLength == 0 || status == .endOfStream || status == .error { break }
        }
    }
    private func flushIdle(at time: Double) {
        // System capture can omit silent buffers. Finalize a quiet track before its converter tail
        // falls behind the 2-second publication boundary; a later sound starts a fresh converter.
        for track in [CaptureTrack.microphone, .system] {
            if let state = converters[track], time - state.lastInputEnd > 0.5 {
                drain(track); converters.removeValue(forKey: track)
            }
        }
    }
    private func append(_ buffer: AVAudioPCMBuffer, state: ConverterState) {
        guard buffer.frameLength > 0, let data = buffer.floatChannelData?[0] else { return }
        let input = Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        if mixed {
            let start = state.nextFrame ?? 0; state.nextFrame = start + input.count
            if let late = mixer.add(input, start: start, gain: timelineGain) { _ = publishWAV(late.samples, start: late.start, kind: "late") }
        } else {
            singleSamples.append(contentsOf: input)
            while active, let count = nextChunkSize(singleSamples[...]) { publishSingle(count: count) }
        }
    }
    private func publishSingle(count: Int) {
        if publishWAV(Array(singleSamples.prefix(count)), start: singleEmittedFrames) { singleSamples.removeFirst(count); singleEmittedFrames += count }
    }
    private func publishMixed(through frame: Int, finish: Bool) {
        while active, let count = nextChunkSize(mixer.samples.prefix(max(0, frame - mixer.emittedFrames))) {
            guard publishWAV(Array(mixer.samples.prefix(count)), start: mixer.emittedFrames) else { return }; mixer.commit(count)
        }
        if finish && !mixer.samples.isEmpty {
            let count = mixer.samples.count
            if publishWAV(mixer.samples, start: mixer.emittedFrames) { mixer.commit(count) }
        }
    }
    private func nextChunkSize(_ samples: ArraySlice<Float>) -> Int? {
        if !liveTranslation { return samples.count >= chunkFrames ? chunkFrames : nil }
        return Self.translationBoundary(samples)
    }
    /// Prefer a 160 ms pause after two seconds; continuous speech is bounded at six.
    /// This only schedules durable audio blocks; Silero performs actual speech detection.
    static func translationBoundary(_ samples: ArraySlice<Float>) -> Int? {
        guard samples.count >= 32000 else { return nil }
        let count = min(samples.count, 96000)
        let tail = samples.prefix(count).suffix(2560)
        let energy = tail.reduce(Float(0)) { $0 + $1 * $1 } / Float(tail.count)
        if energy < 0.000064 { return count }
        return samples.count >= 96000 ? 96000 : nil
    }
    @discardableResult private func publishWAV(_ input: [Float], start: Int, kind: String = "chunk") -> Bool {
        guard !input.isEmpty, let folder else { return true }
        let id = UUID().uuidString, path = folder.appendingPathComponent("\(String(format: "%08d", start))-\(kind)-\(UUID().uuidString).wav")
        do {
            try Self.writeWAV(input, to: path)
            let chunk = AudioChunk(id: id, path: path.path, startSeconds: Double(start) / 16000, durationSeconds: Double(input.count) / 16000)
            publishedChunks.append(chunk); callback?(chunk); return true
        } catch { failure?("录音保存失败：\(error.localizedDescription)。请检查磁盘空间。"); active = false; return false }
    }
    static func writeWAV(_ samples: [Float], to url: URL) throws {
        let byteCount = samples.count * 2
        guard byteCount <= Int(UInt32.max) - 36 else { throw APIError(message: "录音片段过大") }
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var number = value.littleEndian; withUnsafeBytes(of: &number) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var number = value.littleEndian; withUnsafeBytes(of: &number) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(byteCount + 36)); text("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(16000); u32(32000); u16(2); u16(16); text("data"); u32(UInt32(byteCount))
        for sample in samples {
            let finite = sample.isFinite ? sample : 0
            let quantized = Int16(max(-32768, min(32767, Int(finite * 32767))))
            u16(UInt16(bitPattern: quantized))
        }
        try data.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func testFeed(_ buffers: [AVAudioPCMBuffer], directory: URL, liveTranslation: Bool = false, onChunk: @escaping (AudioChunk) -> Void) {
        queue.sync {
            self.liveTranslation = liveTranslation
            folder = directory; callback = onChunk; active = true; mixed = false; singleEmittedFrames = 0; singleSamples = []; converters = [:]
            for buffer in buffers { consume(buffer, track: .microphone, timestamp: 0) }; drain(.microphone)
            if !singleSamples.isEmpty { publishSingle(count: singleSamples.count) }; active = false
        }
    }
    func testMixedFeed(_ microphone: [AVAudioPCMBuffer], system: [AVAudioPCMBuffer], systemOffset: Double, directory: URL, onChunk: @escaping (AudioChunk) -> Void) {
        queue.sync {
            folder = directory; callback = onChunk; active = true; mixed = true; timelineGain = 0.5; anchorSeconds = 100; mixer = TimelineMixer(); converters = [:]
            var events: [(AVAudioPCMBuffer, CaptureTrack, Double)] = []
            for (buffers, track, initial) in [(microphone, CaptureTrack.microphone, 0.0), (system, .system, systemOffset)] {
                var timestamp = 100 + initial
                for buffer in buffers { events.append((buffer, track, timestamp)); timestamp += Double(buffer.frameLength) / buffer.format.sampleRate }
            }
            for event in events.sorted(by: { $0.2 < $1.2 }) {
                flushIdle(at: event.2)
                consume(event.0, track: event.1, timestamp: event.2)
                publishMixed(through: Int((event.2 - 100 - 2) * 16000), finish: false)
            }
            drain(.microphone); drain(.system); publishMixed(through: Int.max, finish: true); active = false
        }
    }
    func testSystemBursts(_ bursts: [(start: Double, buffers: [AVAudioPCMBuffer])], stopSeconds: Double, directory: URL, onChunk: @escaping (AudioChunk) -> Void) {
        queue.sync {
            folder = directory; callback = onChunk; active = true; mixed = true; timelineGain = 1; anchorSeconds = 100; mixer = TimelineMixer(); converters = [:]
            var events: [(AVAudioPCMBuffer, Double)] = []
            for burst in bursts {
                var time = 100 + burst.start
                for buffer in burst.buffers { events.append((buffer, time)); time += Double(buffer.frameLength) / buffer.format.sampleRate }
            }
            for event in events.sorted(by: { $0.1 < $1.1 }) {
                flushIdle(at: event.1); consume(event.0, track: .system, timestamp: event.1)
                let through = Int((event.1 - 100 - 2) * 16000); mixer.ensureEnd(through)
                publishMixed(through: through, finish: false)
            }
            drain(.system); mixer.ensureEnd(Int(stopSeconds * 16000)); publishMixed(through: Int.max, finish: true); active = false
        }
    }
}

