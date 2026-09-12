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
    /// `error` is the first AppleScript failure (typically the Automation permission being denied).
    @MainActor
    static func browserTabs(completion: @escaping @MainActor ([(url: String, title: String)], _ error: String?) -> Void) {
        let browsers = ShortsBrowser.allCases.filter(\.isRunning)
        guard !browsers.isEmpty else { completion([], "지원하는 브라우저가 실행 중이 아니에요"); return }
        var collected: [(url: String, title: String)] = []
        var firstError: String?
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
            run(script, timeout: 6) { output, error in
                if let error, firstError == nil {
                    firstError = error.contains("-1743") || error.lowercased().contains("not authorized")
                        ? "\(browser.name) 제어 권한이 없어요. 시스템 설정 › 개인정보 보호 및 보안 › 자동화에서 ATFM → \(browser.name)을 켜 주세요."
                        : "\(browser.name): \(error.prefix(120))"
                }
                for line in output.split(separator: "\n") {
                    let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    collected.append((url: parts[0], title: parts[1]))
                }
                pending -= 1
                if pending == 0 { completion(collected, firstError) }
            }
        }
    }
}
