import Foundation
import AVFoundation

enum NativeSelfTest {
    static func run() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ZHIHUI_TEST_DIR"] ?? FileManager.default.currentDirectoryPath + "/work/native-audio-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let totalInput = 1_140_000 // 23.75 seconds: two full chunks and a required final remainder.
        var buffers: [AVAudioPCMBuffer] = []; var offset = 0
        while offset < totalInput {
            let frames = min(4096, totalInput - offset)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            for channel in 0..<2 { for frame in 0..<frames { buffer.floatChannelData![channel][frame] = Float(sin(Double(offset + frame) * 2 * .pi * 440 / 48000) * 0.2) } }
            buffers.append(buffer); offset += frames
        }
        var chunks: [AudioChunk] = []
        AudioRecorder().testFeed(buffers, directory: root) { chunks.append($0) }
        guard chunks.count == 3 else { throw APIError(message: "预期3块录音，实际\(chunks.count)") }
        var sampleCount = 0
        for (index, chunk) in chunks.enumerated() {
            let data = try Data(contentsOf: URL(fileURLWithPath: chunk.path))
            guard String(data: data.prefix(4), encoding: .utf8) == "RIFF", String(data: data[8..<12], encoding: .utf8) == "WAVE",
                  data.count > 44, chunk.startSeconds == Double(index * 10) else { throw APIError(message: "WAV格式或连续偏移不正确") }
            let audio = try AVAudioFile(forReading: URL(fileURLWithPath: chunk.path))
            guard audio.processingFormat.sampleRate == 16000, audio.processingFormat.channelCount == 1 else { throw APIError(message: "WAV不是16kHz单声道") }
            if index < 2 { guard audio.length == 160000 else { throw APIError(message: "完整录音块不是10秒") } }
            sampleCount += Int(audio.length)
            let attrs = try FileManager.default.attributesOfItem(atPath: chunk.path)
            guard (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { throw APIError(message: "录音文件权限错误") }
        }
        guard abs(sampleCount - 380000) <= 64 else { throw APIError(message: "录音丢失样本：预期380000，实际\(sampleCount)") }
        let mixed = try verifyMixed(directory: root.appendingPathComponent("mixed", isDirectory: true), format: format)
        let system = try verifySystemGap(directory: root.appendingPathComponent("system-gap", isDirectory: true), format: format)
        let receipt: JSONObject = ["input_sample_rate": 48000, "input_frames": totalInput, "output_sample_rate": 16000, "output_frames": sampleCount, "chunks": chunks.map { ["path": $0.path, "start_seconds": $0.startSeconds, "duration_seconds": $0.durationSeconds] }, "mixed_capture": mixed, "system_silent_gap": system]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("receipt.json"), options: .atomic)
    }
    private static func verifySystemGap(directory: URL, format: AVAudioFormat) throws -> JSONObject {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var buffers: [AVAudioPCMBuffer] = []; var remaining = 240000
        while remaining > 0 {
            let count = min(4096, remaining), buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(min(4096, remaining)))!
            buffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<2 { for frame in 0..<count { buffer.floatChannelData![channel][frame] = 0.2 } }
            buffers.append(buffer); remaining -= count
        }
        var chunks: [AudioChunk] = []
        AudioRecorder().testSystemBursts([(start:0,buffers:buffers),(start:20,buffers:buffers)], stopSeconds:25, directory:directory) { chunks.append($0) }
        guard chunks.count == 3 else { throw APIError(message: "系统声音断流测试预期3块，实际\(chunks.count)") }
        var samples: [Float] = []
        for (index,chunk) in chunks.enumerated() {
            guard chunk.startSeconds == Double(index*10) else { throw APIError(message:"系统声音断流后偏移压缩") }
            let file = try AVAudioFile(forReading: URL(fileURLWithPath:chunk.path))
            let buffer = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length))!
            try file.read(into:buffer); samples.append(contentsOf:UnsafeBufferPointer(start:buffer.floatChannelData![0],count:Int(buffer.frameLength)))
        }
        guard abs(samples.count-400000)<=64 else { throw APIError(message:"系统声音静音时间被压缩：实际\(samples.count)帧，预期400000") }
        func mean(_ from:Double,_ to:Double)->Double { let range=samples[Int(from*16000)..<Int(to*16000)]; return range.reduce(0.0){$0+Double($1)}/Double(range.count) }
        let first=mean(1,4),silence=mean(6,19),resumed=mean(21,24)
        guard abs(first-0.2)<0.005,abs(silence)<0.0001,abs(resumed-0.2)<0.005 else { throw APIError(message:"系统音频恢复/静音/增益测试失败") }
        return ["first_burst_seconds":5,"no_callback_gap_seconds":15,"second_start_seconds":20,"stop_seconds":25,"output_frames":samples.count,"first_mean":first,"silence_mean":silence,"resumed_mean":resumed,"scope":"actual timeline and converter; synthetic system PCM, excludes live ScreenCaptureKit permission"]
    }
    private static func verifyMixed(directory: URL, format: AVAudioFormat) throws -> JSONObject {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func buffers(_ duration: Double, level: Float) -> [AVAudioPCMBuffer] {
            let total = Int(duration * format.sampleRate); var offset = 0; var result: [AVAudioPCMBuffer] = []
            while offset < total {
                let frames = min(4096, total - offset)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!; buffer.frameLength = AVAudioFrameCount(frames)
                for channel in 0..<Int(format.channelCount) { for frame in 0..<frames { buffer.floatChannelData![channel][frame] = level } }
                result.append(buffer); offset += frames
            }
            return result
        }
        var chunks: [AudioChunk] = []
        AudioRecorder().testMixedFeed(buffers(23.75, level: 0.1), system: buffers(4.25, level: 0.2), systemOffset: 2.5, directory: directory) { chunks.append($0) }
        guard chunks.count == 3 else { throw APIError(message: "混音预期3块，实际\(chunks.count)") }
        var mixedSamples: [Float] = []
        for (index, chunk) in chunks.enumerated() {
            guard chunk.startSeconds == Double(index * 10) else { throw APIError(message: "混音时间不是连续0/10/20秒") }
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: chunk.path))
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            mixedSamples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        guard abs(mixedSamples.count - 380000) <= 64 else { throw APIError(message: "双路混音增加/丢失时间，预期380000帧，实际\(mixedSamples.count)") }
        func mean(_ from: Double, _ to: Double) -> Double {
            let values = mixedSamples[Int(from * 16000)..<Int(to * 16000)]
            return values.reduce(0.0) { $0 + Double($1) } / Double(values.count)
        }
        let before = mean(1, 2), overlap = mean(3, 6), after = mean(8, 9), tail = mean(21, 23)
        guard abs(before - 0.05) < 0.005, abs(overlap - 0.15) < 0.005,
              abs(after - 0.05) < 0.005, abs(tail - 0.05) < 0.005 else {
            throw APIError(message: "错开双路混音幅值错误：\(before),\(overlap),\(after),\(tail)")
        }
        let late = TimelineMixer(); _ = late.add(Array(repeating: 1, count: 160000), start: 0); late.commit(160000)
        let recovered = late.add(Array(repeating: 0.2, count: 3200), start: 159000)
        guard recovered?.samples.count == 1000, recovered?.start == 159000, late.samples.count == 2200 else { throw APIError(message: "迟到音频没有完整保留") }
        return ["microphone_seconds":23.75,"system_start_seconds":2.5,"system_seconds":4.25,"mixed_frames":mixedSamples.count,"chunks":chunks.count,"microphone_only_mean":before,"overlap_mean":overlap,"after_system_mean":after,"tail_mean":tail,"late_prefix_retained_frames":1000,"late_remainder_frames":2200,"scope":"real converter and publication; synthetic PCM inputs, excludes hardware permissions"]
    }
}
