import AVFoundation

/// Fallback when ffmpeg is not installed: AVAssetExportSession presets.
enum AVFoundationConverter {
    final class Job {
        fileprivate var session: AVAssetExportSession?
        func cancel() { session?.cancelExport() }
    }

    static func convert(input: URL, output: URL, format: OutputFormat, resolution: VideoResolution,
                        job: Job, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: input)
        let preset: String
        let fileType: AVFileType
        switch format.id {
        case "mp4-hevc":
            preset = AVAssetExportPresetHEVCHighestQuality
            fileType = .mp4
        case "mp4-h264", "mov-h264":
            switch resolution {
            case .p1080: preset = AVAssetExportPreset1920x1080
            case .p720: preset = AVAssetExportPreset1280x720
            case .p480: preset = AVAssetExportPreset640x480
            case .original: preset = AVAssetExportPresetHighestQuality
            }
            fileType = format.ext == "mov" ? .mov : .mp4
        case "m4a":
            preset = AVAssetExportPresetAppleM4A
            fileType = .m4a
        default:
            throw ConvertError.unsupported(format.title)
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConvertError.failed("이 파일은 내장 변환기로 열 수 없어요 (ffmpeg 설치를 권장)")
        }
        session.outputURL = output
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true
        job.session = session

        let poller = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                progress(Double(session.progress))
            }
        }
        defer { poller.cancel() }
        await session.export()
        switch session.status {
        case .completed:
            return
        case .cancelled:
            throw ConvertError.cancelled
        default:
            throw ConvertError.failed(session.error?.localizedDescription ?? "내장 변환기가 실패했어요")
        }
    }
}
