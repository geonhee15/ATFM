import AppKit

/// `ATFM --probe` prints what the system/network samplers can see on this Mac. Debug aid only.
enum Probe {
    /// ATFM_PROBE_CONVERT=<dir> converts test.png / test.mp4 / test.wav found in <dir> through every engine path.
    static func probeConversions(in dir: URL) {
        let ffmpeg = FFmpegConverter.locate()
        print("convert engine: \(ffmpeg?.versionString ?? "builtin") writable images: \(OutputFormat.image.map(\.id))")
        let png = dir.appendingPathComponent("test.png")
        for format in OutputFormat.image where format.id != "png" {
            let out = dir.appendingPathComponent("out-image.\(format.ext)")
            do {
                try ImageConverter.convert(input: png, output: out, format: format, quality: 0.8, maxPixelSize: 256)
                let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
                print("  image → \(format.id): ok \(size) bytes")
            } catch { print("  image → \(format.id): FAIL \(error.localizedDescription)") }
        }
        guard let ffmpeg else { print("  (no ffmpeg; skipping video/audio)"); return }
        let jobs: [(String, String)] = [("test.mp4", "mp4-hevc"), ("test.mp4", "gif-anim"), ("test.mp4", "mp3"), ("test.mp4", "webm-vp9"),
                                        ("test.wav", "mp3"), ("test.wav", "flac"), ("test.wav", "m4a"), ("test.wav", "ogg-opus")]
        let options = FFmpegConverter.VideoOptions(resolution: .p480, quality: .medium, audioBitrate: 192)
        for (file, formatID) in jobs {
            guard let format = (OutputFormat.videoFFmpeg + OutputFormat.audioFFmpeg).first(where: { $0.id == formatID }) else { continue }
            let input = dir.appendingPathComponent(file)
            let out = dir.appendingPathComponent("out-\(file.replacingOccurrences(of: ".", with: "-")).\(format.ext)")
            let args = ffmpeg.arguments(input: input, output: out, format: format, video: options, audioBitrate: 192)
            let semaphore = DispatchSemaphore(value: 0)
            var result = "ok"
            var lastProgress = 0.0
            let job = FFmpegConverter.Job()
            Task.detached {
                do {
                    try await ffmpeg.run(arguments: args, duration: ffmpeg.duration(of: input), job: job) { p in lastProgress = max(lastProgress, p) }
                } catch { result = "FAIL \(error.localizedDescription)" }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 120)
            let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
            print("  \(file) → \(formatID): \(result) \(size) bytes (progress seen \(Int(lastProgress * 100))%)")
        }
    }

    @MainActor
    static func run() {
        print("chip: \(CPUProbe.chipName), cores: \(CPUProbe.coreCount)")
        let thermal = ThermalProbe()
        print("thermal available: \(thermal.isAvailable)")
        let readings = thermal.readAll()
        for r in readings.prefix(40) { print(String(format: "  %-32@ %.1f °C", r.name as NSString, r.celsius)) }
        let summary = ThermalProbe.summarize(readings)
        print("  cpu avg: \(summary.cpu.map { String(format: "%.1f", $0) } ?? "-"), gpu avg: \(summary.gpu.map { String(format: "%.1f", $0) } ?? "-")")
        if let gpu = GPUProbe.sample() { print("gpu: device \(gpu.device)% renderer \(gpu.renderer)% tiler \(gpu.tiler)%") } else { print("gpu: unavailable") }
        if let m = MemoryProbe.sample() {
            print("memory: used \(Format.memory(m.used)) / \(Format.memory(m.total)) app \(Format.memory(m.appMemory)) wired \(Format.memory(m.wired)) compressed \(Format.memory(m.compressed)) swap \(Format.memory(m.swapUsed)) pressure \(m.pressureLevel)")
        }
        if let b = BatteryProbe.sample() {
            print("battery: \(b.percent)% \(b.statusText) temp \(b.temperatureC ?? -1) cycles \(b.cycleCount ?? -1) health \(b.healthPercent ?? -1)")
        } else { print("battery: none") }

        print("step: resolver"); fflush(stdout)
        let resolver = ProcessIdentityResolver()
        print("step: sampler"); fflush(stdout)
        let sampler = ProcessSampler(resolver: resolver)
        print("step: ticks"); fflush(stdout)
        let ticks0 = CPUProbe.perCoreTicks()
        print("step: pids \(ProcessIdentityResolver.allPIDs().count)"); fflush(stdout)
        print("step: identity self = \(resolver.identity(for: getpid()).name)"); fflush(stdout)
        print("step: sample1"); fflush(stdout)
        _ = sampler.sample()
        print("step: sleep"); fflush(stdout)
        Thread.sleep(forTimeInterval: 1.5)
        let usage = CPUProbe.usage(from: ticks0, to: CPUProbe.perCoreTicks())
        print("cpu total: \(String(format: "%.1f", usage.reduce(0, +) / Double(max(1, usage.count))))% per-core: \(usage.map { Int($0) })")
        let apps = sampler.sample().sorted { $0.cpuPercent > $1.cpuPercent }
        print("apps (\(apps.count) groups, energy data: \(sampler.hasEnergyData)):")
        for a in apps.prefix(8) {
            print(String(format: "  %-28@ cpu %5.1f%%  mem %10@  energy %8@  procs %d  app=%@", a.name as NSString, a.cpuPercent, Format.memory(a.memoryBytes) as NSString, Format.milliwatts(a.energyMilliwatts) as NSString, a.processCount, (a.bundlePath != nil) ? "yes" : "no"))
        }
        print("uptime: \(UptimeProbe.format(UptimeProbe.uptime))")
        if let spec = ProcessInfo.processInfo.environment["ATFM_PROBE_LYRICS"] {
            let parts = spec.components(separatedBy: "|")
            if parts.count >= 2 {
                let semaphore = DispatchSemaphore(value: 0)
                let title = parts[0], artist = parts[1]
                let duration = parts.count > 2 ? Double(parts[2]) ?? 0 : 0
                Task.detached {
                    do {
                        let candidates = try await LyricsService.candidates(title: title, artist: artist, album: "", duration: duration)
                        print("lyrics: \(candidates.count) candidates")
                        for c in candidates.prefix(6) {
                            print(String(format: "  score %5.0f  hangul=%@  %@", LyricsService.score(c, title: title, artist: artist, duration: duration), c.containsHangul ? "yes" : "no ", c.summary as NSString))
                        }
                        if let best = candidates.first {
                            for line in (best.lyrics().synced ?? []).prefix(3) { print(String(format: "  [%6.2f] %@", line.time, line.text as NSString)) }
                        }
                    } catch { print("lyrics: error \(error.localizedDescription)") }
                    semaphore.signal()
                }
                _ = semaphore.wait(timeout: .now() + 30)
            }
        }
        if ProcessInfo.processInfo.environment["ATFM_PROBE_NOWPLAYING"] == "1" {
            if let resources = NowPlayingMonitor.bridgeResources {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
                process.arguments = [resources.script.path, resources.dylib.path]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardInput = Pipe()
                try? process.run()
                Thread.sleep(forTimeInterval: 3)
                process.terminate()
                let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                for line in text.split(separator: "\n").prefix(3) {
                    var shown = String(line)
                    if let range = shown.range(of: "\"artwork\":\"") {
                        shown = String(shown[..<range.lowerBound]) + "\"artwork\":\"…\"}"
                    }
                    print("nowplaying: \(shown.prefix(300))")
                }
                if text.isEmpty { print("nowplaying: (no output)") }
            } else {
                print("nowplaying: bridge resources missing")
            }
        }
        if let spec = ProcessInfo.processInfo.environment["ATFM_PROBE_DOWNLOAD"] {
            // ATFM_PROBE_DOWNLOAD="<url>|<dir>[|quality]" — real download through MediaDownloader, prints progress.
            let parts = spec.components(separatedBy: "|")
            if parts.count >= 2 {
                let downloader = MediaDownloader()
                print("download probe: yt-dlp=\(downloader.ytdlpPath ?? "missing")")
                downloader.url = parts[0]
                if parts.count > 2, let q = DownloadQuality(rawValue: parts[2]) { downloader.quality = q }
                UserDefaults.standard.set(parts[1], forKey: "downloadDirectory")
                let fresh = MediaDownloader()
                fresh.url = parts[0]
                fresh.quality = downloader.quality
                fresh.start()
                var lastPrinted = ""
                let deadline = Date().addingTimeInterval(180)
                while fresh.isBusy, Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
                    let line = "  \(fresh.phase) \(Int(fresh.progress * 100))% \(fresh.sizeText) \(fresh.speed) eta \(fresh.eta) title='\(fresh.title)'"
                    if line != lastPrinted, fresh.phase == .downloading || fresh.phase == .merging { print(line); lastPrinted = line }
                }
                switch fresh.phase {
                case .done: print("download probe: done → \(fresh.lastFile?.path ?? "-") (\(fresh.duration), \(fresh.resolution))")
                case .failed(let m): print("download probe: failed: \(m)")
                default: print("download probe: still \(fresh.phase) at timeout")
                }
                UserDefaults.standard.removeObject(forKey: "downloadDirectory")
            }
        }
        if ProcessInfo.processInfo.environment["ATFM_PROBE_HOTKEY"] == "1" {
            // Key-cap names + a real Carbon registration round-trip for the default combos.
            MainActor.assumeIsolated {
                for action in ToolHotkeys.Action.allCases {
                    let combo = action.defaultCombo
                    let result = HotkeyCenter.shared.register(combo) {}
                    switch result {
                    case .success(let id):
                        print("hotkey probe: \(action.rawValue) = \(combo.display) registered (id \(id))")
                        HotkeyCenter.shared.unregister(id)
                    case .failure(let error):
                        print("hotkey probe: \(action.rawValue) = \(combo.display) FAILED \(error.message)")
                    }
                }
                let samples: [UInt16] = [0, 12, 18, 29, 49, 122, 126, 44, 27, 24]
                print("hotkey probe: key names " + samples.map { "\($0)=\(KeyCombo.keyName(for: $0))" }.joined(separator: " "))
                let shiftOnly = KeyCombo(keyCode: 0, flags: [.shift])
                print("hotkey probe: shift-only usable = \(shiftOnly.isUsable), F1 usable = \(KeyCombo(keyCode: 122, flags: []).isUsable)")
            }
        }
        if ProcessInfo.processInfo.environment["ATFM_PROBE_OCR"] == "1" {
            // Draws Korean + English text into a bitmap and runs the Vision path used by 빠른 툴.
            let image = NSImage(size: NSSize(width: 760, height: 220), flipped: false) { rect in
                NSColor.white.setFill()
                rect.fill()
                let text = NSAttributedString(string: "안녕하세요, ATFM 빠른 툴 테스트입니다.\nScreen text capture 1234 · 서울시 강남구 테헤란로",
                                              attributes: [.font: NSFont.systemFont(ofSize: 26, weight: .medium),
                                                           .foregroundColor: NSColor.black])
                text.draw(in: rect.insetBy(dx: 30, dy: 50))
                return true
            }
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let semaphore = DispatchSemaphore(value: 0)
                Task.detached {
                    let text = await ScreenOCR.recognize(cg)
                    print("ocr probe (\(cg.width)x\(cg.height)):\n\(text)")
                    semaphore.signal()
                }
                _ = semaphore.wait(timeout: .now() + 30)
            } else {
                print("ocr probe: could not render the test image")
            }
        }
        if let dir = ProcessInfo.processInfo.environment["ATFM_PROBE_CONVERT"] {
            Self.probeConversions(in: URL(fileURLWithPath: dir))
        }
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            func log(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
            log("gemini step: start")
            GeminiAPI.debugLog = { log("  " + $0) }
            do {
                var probeRequest = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")!)
                probeRequest.httpMethod = "POST"
                probeRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                probeRequest.setValue("invalid-key-for-probe", forHTTPHeaderField: "x-goog-api-key")
                probeRequest.httpBody = Data("{\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":\"hi\"}]}]}".utf8)
                let (data, response) = try await URLSession.shared.data(for: probeRequest)
                log("gemini step: data(for:) status \((response as? HTTPURLResponse)?.statusCode ?? -1) bytes \(data.count)")
            } catch {
                log("gemini step: data(for:) error \(error.localizedDescription)")
            }
            do {
                var received = ""
                for try await event in GeminiAPI.stream(apiKey: "invalid-key-for-probe", model: "gemini-2.5-flash",
                                                        history: [ChatMessage(id: UUID(), role: .user, text: "hi", date: Date())],
                                                        useSearch: false) {
                    if case .text(let chunk) = event { received += chunk }
                }
                print("gemini probe: unexpected success \(received.prefix(40))")
            } catch {
                print("gemini probe (invalid key → expected error): \(error.localizedDescription)")
            }
            // With a stored key (ATFM_PROBE_LIVE=1): list models, pick one, ask a grounded question.
            if ProcessInfo.processInfo.environment["ATFM_PROBE_LIVE"] == "1",
               let key = UserDefaults.standard.string(forKey: "geminiAPIKey"), !key.isEmpty {
                do {
                    let models = try await GeminiAPI.listModels(apiKey: key)
                    log("live models (\(models.count)): \(models.joined(separator: ", "))")
                    let saved = UserDefaults.standard.string(forKey: "geminiModel") ?? "-"
                    let env = ProcessInfo.processInfo.environment
                    let pick = env["ATFM_PROBE_MODEL"] ?? (models.contains(saved) ? saved : (GeminiChat.bestModel(from: models) ?? saved))
                    let search = env["ATFM_PROBE_SEARCH"] != "0"
                    log("live model: saved=\(saved) using=\(pick) search=\(search) best=\(GeminiChat.bestModel(from: models) ?? "-")")
                    let prompt = ProcessInfo.processInfo.environment["ATFM_PROBE_PROMPT"] ?? "내일 인천 날씨 어때? 두 문장으로."
                    var answer = ""
                    var sources: [WebSource] = []
                    for try await event in GeminiAPI.stream(apiKey: key, model: pick,
                                                            history: [ChatMessage(id: UUID(), role: .user, text: prompt, date: Date())],
                                                            useSearch: search) {
                        switch event {
                        case .text(let t): answer += t
                        case .sources(let s): sources += s
                        }
                    }
                    log("live answer: \(answer.replacingOccurrences(of: "\n", with: " ").prefix(300))")
                    log("live sources: \(sources.map(\.title).prefix(5))")
                } catch {
                    log("live error: \(error.localizedDescription)")
                }
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 90)
        let handle = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        print("corebrightness dlopen: \(handle != nil) \(handle == nil ? String(cString: dlerror()) : "")")
        if let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
            let obj = cls.init()
            for name in ["copyKeyboardBackgroundServiceIDs", "brightnessForKeyboard:", "setBrightness:forKeyboard:", "isKeyboardBuiltIn:", "enableAutoBrightness:forKeyboard:"] {
                print("  responds \(name): \(obj.responds(to: NSSelectorFromString(name)))")
            }
            var count: UInt32 = 0
            if let methods = class_copyMethodList(cls, &count) {
                let names = (0..<Int(count)).map { NSStringFromSelector(method_getName(methods[$0])) }
                print("  methods: \(names.sorted().joined(separator: " | "))")
                free(methods)
            }
            typealias BoolForID = @convention(c) (AnyObject, Selector, UInt64) -> Bool
            typealias FloatForID = @convention(c) (AnyObject, Selector, UInt64) -> Float
            if let send = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") {
                let builtIn = unsafeBitCast(send, to: BoolForID.self)
                let bright = unsafeBitCast(send, to: FloatForID.self)
                for id: UInt64 in 0...3 {
                    print("  id \(id): builtIn \(builtIn(obj, NSSelectorFromString("isKeyboardBuiltIn:"), id)) brightness \(bright(obj, NSSelectorFromString("brightnessForKeyboard:"), id))")
                }
            }
        } else {
            print("  KeyboardBrightnessClient class not found")
        }
        do { _ = try FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/.Trash") } catch { print("trash read error: \(error.localizedDescription)") }
        let kb = KeyboardBacklight()
        print("keyboard backlight: available \(kb.isAvailable), brightness \(kb.brightness.map { String($0) } ?? "-"), set(same) ok: \(kb.setBrightness(kb.brightness ?? 0))")
        print("lock screen symbol: \(ScreenControl.canLock)")
        print("finder hidden files: \(FinderPrefs.showsHiddenFiles), desktop icons: \(FinderPrefs.desktopIconsVisible)")
        print("trash items: \(TrashInfo.itemCount.map(String.init) ?? "-"), external volumes: \(Volumes.external().map(\.lastPathComponent))")
    }
}
