// ATFMMediaRemote.dylib — loaded by /usr/bin/perl (an Apple platform binary) so MediaRemote hands out
// Now Playing info, which it refuses to third-party processes since macOS 15.4.
// Protocol: one JSON object per line on stdout; commands (play/pause/toggle/next/prev/seek <s>) on stdin.
import Foundation

private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
private typealias GetBoolFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
private typealias GetPIDFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
private typealias SendCommandFn = @convention(c) (Int32, CFDictionary?) -> Bool

final class MediaRemoteBridge {
    static let shared = MediaRemoteBridge()

    private var getInfo: GetInfoFn?
    private var getIsPlaying: GetBoolFn?
    private var getPID: GetPIDFn?
    private var register: RegisterFn?
    private var sendCommand: SendCommandFn?
    private var lastArtworkKey = ""
    private var lastPayload = ""
    private var pendingRefresh = false

    private init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) else { return }
        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") { getInfo = unsafeBitCast(sym, to: GetInfoFn.self) }
        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") { getIsPlaying = unsafeBitCast(sym, to: GetBoolFn.self) }
        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID") { getPID = unsafeBitCast(sym, to: GetPIDFn.self) }
        if let sym = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") { register = unsafeBitCast(sym, to: RegisterFn.self) }
        if let sym = dlsym(handle, "MRMediaRemoteSendCommand") { sendCommand = unsafeBitCast(sym, to: SendCommandFn.self) }
    }

    func start() {
        guard getInfo != nil else {
            emitLine(["error": "MediaRemote unavailable"])
            return
        }
        register?(DispatchQueue.main)
        let names = [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            "kMRMediaRemoteNowPlayingPlaybackQueueDidChangeNotification",
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                self?.scheduleRefresh()
            }
        }
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.refresh() }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let line = readLine() {
                DispatchQueue.main.async { self?.handle(command: line.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            exit(0)   // parent closed stdin
        }
        refresh()
        RunLoop.main.run()
    }

    private func scheduleRefresh() {
        guard !pendingRefresh else { return }
        pendingRefresh = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.pendingRefresh = false
            self?.refresh()
        }
    }

    private func refresh() {
        guard let getInfo, let getIsPlaying, let getPID else { return }
        getPID(DispatchQueue.main) { pid in
            getIsPlaying(DispatchQueue.main) { playing in
                getInfo(DispatchQueue.main) { [weak self] dict in
                    self?.emit(info: dict as? [String: Any], pid: pid, playing: playing)
                }
            }
        }
    }

    private func emit(info: [String: Any]?, pid: Int32, playing: Bool) {
        var payload: [String: Any] = ["playing": playing, "pid": Int(pid)]
        if let info, !info.isEmpty {
            payload["title"] = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
            payload["artist"] = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            payload["album"] = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
            payload["duration"] = (info["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0
            payload["elapsed"] = (info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0
            payload["rate"] = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? (playing ? 1 : 0)
            if let date = info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date {
                payload["timestamp"] = date.timeIntervalSince1970
            }
            if let artwork = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data, !artwork.isEmpty {
                let key = "\(artwork.count):\(artwork.prefix(64).hashValue):\(payload["title"] ?? "")"
                if key != lastArtworkKey {
                    lastArtworkKey = key
                    payload["artwork"] = artwork.base64EncodedString()
                }
                payload["hasArtwork"] = true
            } else {
                lastArtworkKey = ""
                payload["hasArtwork"] = false
            }
        } else {
            payload["empty"] = true
            lastArtworkKey = ""
        }
        emitLine(payload)
    }

    private func emitLine(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return }
        // Skip exact duplicates except when they carry artwork (the app needs it once).
        if text == lastPayload, object["artwork"] == nil { return }
        lastPayload = text
        print(text)
        fflush(stdout)
    }

    private func handle(command: String) {
        let parts = command.split(separator: " ")
        guard let name = parts.first else { return }
        let code: Int32
        switch name {
        case "play": code = 0
        case "pause": code = 1
        case "toggle": code = 2
        case "next": code = 4
        case "prev", "previous": code = 5
        case "seek":
            guard parts.count > 1, let seconds = Double(parts[1]) else { return }
            _ = sendCommand?(24, ["kMRMediaRemoteOptionPlaybackPosition": seconds] as CFDictionary)
            scheduleRefresh()
            return
        case "refresh":
            refresh()
            return
        default: return
        }
        _ = sendCommand?(code, nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
    }
}

@_cdecl("atfm_mediaremote_main")
public func atfm_mediaremote_main(_ interpreter: UnsafeMutableRawPointer?, _ cv: UnsafeMutableRawPointer?) {
    MediaRemoteBridge.shared.start()
}
