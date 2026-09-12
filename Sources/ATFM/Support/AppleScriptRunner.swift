import Foundation

/// Runs AppleScript through /usr/bin/osascript off the main thread and reports back on it.
enum AppleScriptRunner {
    static func run(_ script: String, timeout: TimeInterval = 10, completion: @escaping @MainActor (String, String?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]
        let input = Pipe(), output = Pipe(), errorPipe = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            Task { @MainActor in completion("", error.localizedDescription) }
            return
        }
        input.fileHandleForWriting.write(Data(script.utf8))
        try? input.fileHandleForWriting.close()
        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
            let outData = output.fileHandleForReading.readDataToEndOfFile()
            let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let out = String(decoding: outData, as: UTF8.self)
            let err = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let failed = process.terminationStatus != 0 || !err.isEmpty
            Task { @MainActor in completion(out, failed ? (err.isEmpty ? "osascript 종료 코드 \(process.terminationStatus)" : err) : nil) }
        }
    }

    /// `URL<TAB>title` per line for every tab of every running browser we can talk to.
    @MainActor
    static func browserTabs(completion: @escaping @MainActor ([(url: String, title: String)]) -> Void) {
        let browsers = ShortsBrowser.allCases.filter(\.isRunning)
        guard !browsers.isEmpty else { completion([]); return }
        var collected: [(url: String, title: String)] = []
        var pending = browsers.count
        for browser in browsers {
            let titleKey = browser.isSafari ? "name of t" : "title of t"
            let script = """
            tell application id "\(browser.rawValue)"
                set out to ""
                repeat with w in windows
                    repeat with t in tabs of w
                        set out to out & (URL of t) & tab & (\(titleKey)) & linefeed
                    end repeat
                end repeat
                return out
            end tell
            """
            run(script, timeout: 6) { output, _ in
                for line in output.split(separator: "\n") {
                    let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    collected.append((url: parts[0], title: parts[1]))
                }
                pending -= 1
                if pending == 0 { completion(collected) }
            }
        }
    }
}
