import Foundation

/// Drives the Homebrew/MacPorts ffmpeg binary with `-progress pipe:1` for live progress.
final class FFmpegConverter {
    let ffmpegPath: String
    let ffprobePath: String?

    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]

    static func locate() -> FFmpegConverter? {
        for dir in searchPaths {
            let ffmpeg = dir + "/ffmpeg"
            if FileManager.default.isExecutableFile(atPath: ffmpeg) {
                let probe = dir + "/ffprobe"
                return FFmpegConverter(ffmpegPath: ffmpeg, ffprobePath: FileManager.default.isExecutableFile(atPath: probe) ? probe : nil)
            }
        }
        return nil
    }

    init(ffmpegPath: String, ffprobePath: String?) {
        self.ffmpegPath = ffmpegPath
        self.ffprobePath = ffprobePath
    }

    var versionString: String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = ["-version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "ffmpeg" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let first = String(decoding: data, as: UTF8.self).split(separator: "\n").first ?? "ffmpeg"
        let parts = first.split(separator: " ")
        return parts.count >= 3 ? "ffmpeg \(parts[2])" : "ffmpeg"
    }

    func duration(of url: URL) -> Double? {
        guard let ffprobePath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = ["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Double(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Argument building

    struct VideoOptions {
        var resolution: VideoResolution
        var quality: VideoQuality
        var audioBitrate: Int
    }

    func arguments(input: URL, output: URL, format: OutputFormat, video: VideoOptions, audioBitrate: Int) -> [String] {
        var args = ["-y", "-hide_banner", "-nostdin", "-loglevel", "error", "-progress", "pipe:1", "-nostats", "-i", input.path]
        let scale: [String] = video.resolution == .original ? [] : ["-vf", "scale=-2:'min(\(video.resolution.rawValue),ih)'"]
        switch format.id {
        case "mp4-h264", "mov-h264", "mkv-h264":
            args += scale + ["-c:v", "h264_videotoolbox", "-q:v", "\(video.quality.vtQuality)", "-allow_sw", "1",
                             "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "\(video.audioBitrate)k"]
            if format.ext != "mkv" { args += ["-movflags", "+faststart"] }
        case "mp4-hevc", "mov-hevc":
            args += scale + ["-c:v", "hevc_videotoolbox", "-q:v", "\(video.quality.vtQuality)", "-allow_sw", "1",
                             "-tag:v", "hvc1", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "\(video.audioBitrate)k", "-movflags", "+faststart"]
        case "webm-vp9":
            args += scale + ["-c:v", "libvpx-vp9", "-crf", "\(video.quality.vp9CRF)", "-b:v", "0", "-row-mt", "1",
                             "-deadline", "good", "-cpu-used", "4", "-c:a", "libopus", "-b:a", "128k"]
        case "gif-anim":
            let width = video.resolution == .original ? 640 : min(640, video.resolution.rawValue)
            let fps = video.quality == .high ? 15 : (video.quality == .medium ? 12 : 8)
            args += ["-vf", "fps=\(fps),scale='min(\(width),iw)':-2:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse",
                     "-loop", "0"]
        case "mp3":
            args += ["-vn", "-c:a", "libmp3lame", "-b:a", "\(audioBitrate)k"]
        case "m4a":
            args += ["-vn", "-c:a", "aac", "-b:a", "\(audioBitrate)k"]
        case "wav":
            args += ["-vn", "-c:a", "pcm_s16le"]
        case "aiff":
            args += ["-vn", "-c:a", "pcm_s16be"]
        case "flac":
            args += ["-vn", "-c:a", "flac"]
        case "ogg-opus":
            args += ["-vn", "-c:a", "libopus", "-b:a", "\(min(audioBitrate, 256))k"]
        default:
            break
        }
        args.append(output.path)
        return args
    }

    // MARK: Running

    final class Job {
        fileprivate var process: Process?
        func cancel() {
            if let process, process.isRunning { process.terminate() }
        }
    }

    func run(arguments: [String], duration: Double?, job: Job, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = arguments
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            var buffer = Data()
            let bufferLock = NSLock()
            out.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                bufferLock.lock()
                buffer.append(data)
                var latestTime: Double?
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if line.hasPrefix("out_time_us="), let value = Double(line.dropFirst("out_time_us=".count)) {
                        latestTime = value / 1_000_000
                    } else if line.hasPrefix("out_time_ms="), let value = Double(line.dropFirst("out_time_ms=".count)) {
                        latestTime = value / 1_000_000
                    }
                }
                bufferLock.unlock()
                if let latestTime, let duration, duration > 0 {
                    progress(min(0.99, max(0, latestTime / duration)))
                }
            }
            var errorOutput = Data()
            err.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { errorOutput.append(data) }
            }
            process.terminationHandler = { finished in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                errorOutput.append(err.fileHandleForReading.readDataToEndOfFile())
                if finished.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: ConvertError.cancelled)
                } else if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let message = String(decoding: errorOutput, as: UTF8.self)
                        .split(separator: "\n").last.map(String.init) ?? "ffmpeg 오류 (\(finished.terminationStatus))"
                    continuation.resume(throwing: ConvertError.failed(message))
                }
            }
            job.process = process
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ConvertError.failed("ffmpeg를 실행하지 못했어요: \(error.localizedDescription)"))
            }
        }
    }
}
