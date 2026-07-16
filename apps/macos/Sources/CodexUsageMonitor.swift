import AppKit
import Foundation

private struct UsageWindow {
    var usedPercent: Int = 0
    var durationMinutes: Int?
    var resetsAt: Date?
}

private struct UsageSnapshot {
    var plan = "unknown"
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    var creditBalance = "0"
    var hasCredits = false
    var unlimitedCredits = false
    var todayTokens: Int64 = 0
    var lifetimeTokens: Int64 = 0
    var peakDailyTokens: Int64 = 0
    var streakDays: Int64 = 0
    var updatedAt = Date()
}

private enum MonitorError: LocalizedError {
    case codexNotFound
    case appServerExited
    case invalidResponse(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "找不到 Codex 本地 app-server（已检查 CLI 和 ChatGPT.app）。"
        case .appServerExited:
            return "Codex app-server 已退出。"
        case .invalidResponse(let detail):
            return "Codex 返回了无法识别的数据：\(detail)"
        case .timeout:
            return "读取用量超时。"
        }
    }
}

private final class AppServerClient {
    private let queue = DispatchQueue(label: "codex.usage.monitor.app-server")
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var nextID = 1
    private var initialized = false
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var readyWaiters: [(Result<Void, Error>) -> Void] = []

    deinit {
        stop()
    }

    func fetch(completion: @escaping (Result<UsageSnapshot, Error>) -> Void) {
        ensureConnected { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                DispatchQueue.main.async { completion(.failure(error)) }
            case .success:
                self.fetchConnected(completion: completion)
            }
        }
    }

    func stop() {
        queue.sync {
            input?.closeFile()
            process?.terminate()
            input = nil
            process = nil
            initialized = false
        }
    }

    private func ensureConnected(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            if self.initialized, self.process?.isRunning == true {
                completion(.success(()))
                return
            }

            self.readyWaiters.append(completion)
            guard self.process == nil else { return }

            do {
                try self.launchLocked()
                self.requestLocked(
                    method: "initialize",
                    params: [
                        "clientInfo": [
                            "name": "codex-usage-monitor",
                            "title": "Codex Usage Monitor",
                            "version": "0.1.0",
                        ],
                        "capabilities": ["experimentalApi": true],
                    ]
                ) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .failure(let error):
                        self.finishReadyLocked(.failure(error))
                    case .success:
                        self.sendLocked(["method": "initialized"])
                        self.initialized = true
                        self.finishReadyLocked(.success(()))
                    }
                }
            } catch {
                self.finishReadyLocked(.failure(error))
            }
        }
    }

    private func launchLocked() throws {
        guard let codexPath = Self.resolveCodexPath() else {
            throw MonitorError.codexNotFound
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consumeLocked(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.handleExitLocked() }
        }

        try process.run()
        self.process = process
        self.input = stdinPipe.fileHandleForWriting
    }

    private func fetchConnected(completion: @escaping (Result<UsageSnapshot, Error>) -> Void) {
        queue.async {
            var rateResult: [String: Any]?
            var usageResult: [String: Any]?
            var firstError: Error?
            var finished = false

            let finishIfReady = {
                guard !finished else { return }
                if let error = firstError {
                    finished = true
                    DispatchQueue.main.async { completion(.failure(error)) }
                    return
                }
                guard let rateResult, let usageResult else { return }
                finished = true
                do {
                    let snapshot = try Self.makeSnapshot(rate: rateResult, usage: usageResult)
                    DispatchQueue.main.async { completion(.success(snapshot)) }
                } catch {
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }

            self.requestLocked(method: "account/rateLimits/read", params: nil) { result in
                switch result {
                case .success(let value): rateResult = value
                case .failure(let error): firstError = error
                }
                finishIfReady()
            }
            self.requestLocked(method: "account/usage/read", params: nil) { result in
                switch result {
                case .success(let value): usageResult = value
                case .failure(let error): firstError = error
                }
                finishIfReady()
            }

            self.queue.asyncAfter(deadline: .now() + 15) {
                guard !finished else { return }
                finished = true
                DispatchQueue.main.async { completion(.failure(MonitorError.timeout)) }
            }
        }
    }

    private func requestLocked(
        method: String,
        params: Any?,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        let id = nextID
        nextID += 1
        pending[id] = completion
        var message: [String: Any] = ["id": id, "method": method]
        message["params"] = params ?? NSNull()
        sendLocked(message)
    }

    private func sendLocked(_ message: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(message),
              var data = try? JSONSerialization.data(withJSONObject: message)
        else { return }
        data.append(0x0A)
        input?.write(data)
    }

    private func consumeLocked(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let message = object as? [String: Any]
            else { continue }

            if let idNumber = message["id"] as? NSNumber,
               let callback = pending.removeValue(forKey: idNumber.intValue) {
                if let error = message["error"] as? [String: Any] {
                    callback(.failure(MonitorError.invalidResponse(String(describing: error))))
                } else if let result = message["result"] as? [String: Any] {
                    callback(.success(result))
                } else {
                    callback(.failure(MonitorError.invalidResponse("缺少 result")))
                }
            }
        }
    }

    private func handleExitLocked() {
        let callbacks = pending.values
        pending.removeAll()
        initialized = false
        input = nil
        process = nil
        callbacks.forEach { $0(.failure(MonitorError.appServerExited)) }
        finishReadyLocked(.failure(MonitorError.appServerExited))
    }

    private func finishReadyLocked(_ result: Result<Void, Error>) {
        let callbacks = readyWaiters
        readyWaiters.removeAll()
        callbacks.forEach { $0(result) }
    }

    private static func resolveCodexPath() -> String? {
        let manager = FileManager.default
        var candidates = [
            ProcessInfo.processInfo.environment["CODEX_BIN"],
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
            NSHomeDirectory() + "/.local/bin/codex",
            NSHomeDirectory() + "/.volta/bin/codex",
            NSHomeDirectory() + "/.asdf/shims/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            NSHomeDirectory() + "/Applications/ChatGPT.app/Contents/Resources/codex",
        ].compactMap { $0 }

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }

        let nvmVersions = NSHomeDirectory() + "/.nvm/versions/node"
        if let versions = try? manager.contentsOfDirectory(atPath: nvmVersions) {
            candidates.append(contentsOf: versions.map { "\(nvmVersions)/\($0)/bin/codex" })
        }

        if let shellPath = resolveFromLoginShell() {
            candidates.append(shellPath)
        }
        return candidates.first(where: { manager.isExecutableFile(atPath: $0) })
    }

    private static func resolveFromLoginShell() -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v codex 2>/dev/null"]
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return path?.isEmpty == false ? path : nil
        } catch {
            return nil
        }
    }

    private static func makeSnapshot(rate: [String: Any], usage: [String: Any]) throws -> UsageSnapshot {
        let byID = rate["rateLimitsByLimitId"] as? [String: Any]
        let selected = (byID?["codex"] as? [String: Any]) ?? (rate["rateLimits"] as? [String: Any])
        guard let selected else { throw MonitorError.invalidResponse("缺少 rateLimits") }

        var snapshot = UsageSnapshot()
        snapshot.plan = selected["planType"] as? String ?? "unknown"
        let windows = [
            parseWindow(selected["primary"] as? [String: Any]),
            parseWindow(selected["secondary"] as? [String: Any]),
        ].compactMap { $0 }
        snapshot.fiveHour = windows.first(where: { ($0.durationMinutes ?? 0) > 0 && ($0.durationMinutes ?? 0) <= 720 })
        snapshot.sevenDay = windows.first(where: { ($0.durationMinutes ?? 0) >= 1440 })
        // Older app-server versions may omit window duration. Preserve the historical order only when
        // there is no duration-based classification available.
        if snapshot.fiveHour == nil && snapshot.sevenDay == nil {
            snapshot.fiveHour = windows.first
            snapshot.sevenDay = windows.dropFirst().first
        }

        if let credits = selected["credits"] as? [String: Any] {
            snapshot.creditBalance = credits["balance"] as? String ?? "0"
            snapshot.hasCredits = credits["hasCredits"] as? Bool ?? false
            snapshot.unlimitedCredits = credits["unlimited"] as? Bool ?? false
        }

        if let summary = usage["summary"] as? [String: Any] {
            snapshot.lifetimeTokens = int64(summary["lifetimeTokens"])
            snapshot.peakDailyTokens = int64(summary["peakDailyTokens"])
            snapshot.streakDays = int64(summary["currentStreakDays"])
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        if let buckets = usage["dailyUsageBuckets"] as? [[String: Any]],
           let bucket = buckets.first(where: { ($0["startDate"] as? String) == today }) {
            snapshot.todayTokens = int64(bucket["tokens"])
        }
        snapshot.updatedAt = Date()
        return snapshot
    }

    private static func parseWindow(_ value: [String: Any]?) -> UsageWindow? {
        guard let value else { return nil }
        let epoch = int64(value["resetsAt"])
        return UsageWindow(
            usedPercent: Int(int64(value["usedPercent"])),
            durationMinutes: value["windowDurationMins"].map { Int(int64($0)) },
            resetsAt: epoch > 0 ? Date(timeIntervalSince1970: TimeInterval(epoch)) : nil
        )
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) ?? 0 }
        return 0
    }
}

private final class DashboardView: NSView {
    var snapshot: UsageSnapshot? { didSet { needsDisplay = true } }
    var errorMessage: String? { didSet { needsDisplay = true } }
    var isLoading = true { didSet { needsDisplay = true } }
    let refreshButton = NSButton(title: "立即刷新", target: nil, action: nil)
    let minimizeButton = NSButton(title: "最小化", target: nil, action: nil)
    let quitButton = NSButton(title: "完全退出", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        refreshButton.bezelStyle = .rounded
        minimizeButton.bezelStyle = .rounded
        quitButton.bezelStyle = .rounded
        addSubview(refreshButton)
        addSubview(minimizeButton)
        addSubview(quitButton)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        refreshButton.frame = NSRect(x: 22, y: 18, width: 88, height: 30)
        minimizeButton.frame = NSRect(x: 120, y: 18, width: 90, height: 30)
        quitButton.frame = NSRect(x: bounds.width - 98, y: 18, width: 76, height: 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(calibratedWhite: 0.09, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18).fill()

        drawText("Codex 用量监控", x: 22, y: 333, size: 19, weight: .semibold, color: .white)
        let stateText = isLoading ? "正在读取…" : (errorMessage == nil ? "● 实时" : "● 暂不可用")
        let stateColor = errorMessage == nil ? NSColor.systemGreen : NSColor.systemOrange
        drawRightText(stateText, right: bounds.width - 22, y: 337, size: 12, weight: .medium, color: stateColor)

        if let snapshot {
            drawText(snapshot.plan.uppercased(), x: 22, y: 303, size: 11, weight: .bold, color: .systemTeal)
            drawWindow("5 小时窗口", window: snapshot.fiveHour, y: 250)
            drawWindow("7 天窗口", window: snapshot.sevenDay, y: 190)

            drawMetric("今日 Token", value: formatTokens(snapshot.todayTokens), x: 22, y: 128)
            drawMetric("累计 Token", value: formatTokens(snapshot.lifetimeTokens), x: 174, y: 128)
            drawMetric("Credits", value: snapshot.unlimitedCredits ? "无限" : snapshot.creditBalance, x: 22, y: 78)
            drawMetric("连续活跃", value: "\(snapshot.streakDays) 天", x: 174, y: 78)

            let updated = Self.timeFormatter.string(from: snapshot.updatedAt)
            drawText("更新于 \(updated) · 拖动面板可移动", x: 22, y: 53, size: 10, weight: .regular, color: mutedColor)
        } else if let errorMessage {
            drawWrappedText(errorMessage, x: 22, y: 240, width: 296, size: 13, weight: .regular, color: .systemOrange)
        }
    }

    private func drawWindow(_ title: String, window: UsageWindow?, y: CGFloat) {
        drawText(title, x: 22, y: y + 28, size: 12, weight: .medium, color: NSColor(calibratedWhite: 0.90, alpha: 1))

        let track = NSRect(x: 22, y: y + 10, width: 296, height: 8)
        NSColor(calibratedWhite: 0.25, alpha: 1).setFill()
        NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
        guard let window else {
            drawRightText("暂无数据", right: bounds.width - 22, y: y + 28, size: 12, weight: .semibold, color: mutedColor)
            drawText("等待服务端提供此窗口", x: 22, y: y - 7, size: 10, weight: .regular, color: mutedColor)
            return
        }

        let remaining = max(0, 100 - window.usedPercent)
        drawRightText("剩余 \(remaining)%", right: bounds.width - 22, y: y + 28, size: 12, weight: .semibold, color: color(forRemaining: remaining))
        let fillWidth = track.width * CGFloat(remaining) / 100
        color(forRemaining: remaining).setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: fillWidth, height: track.height), xRadius: 4, yRadius: 4).fill()

        let reset = window.resetsAt.map { "重置：\(Self.dateFormatter.string(from: $0))" } ?? "重置时间未知"
        drawText(reset, x: 22, y: y - 7, size: 10, weight: .regular, color: mutedColor)
    }

    private func drawMetric(_ title: String, value: String, x: CGFloat, y: CGFloat) {
        drawText(title, x: x, y: y + 18, size: 10, weight: .medium, color: mutedColor)
        drawText(value, x: x, y: y - 4, size: 18, weight: .semibold, color: .white)
    }

    private func drawText(
        _ text: String,
        x: CGFloat,
        y: CGFloat,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) {
        (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: textAttributes(size: size, weight: weight, color: color))
    }

    private func drawRightText(
        _ text: String,
        right: CGFloat,
        y: CGFloat,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) {
        let attributes = textAttributes(size: size, weight: weight, color: color)
        let width = (text as NSString).size(withAttributes: attributes).width
        drawText(text, x: right - width, y: y, size: size, weight: weight, color: color)
    }

    private func drawWrappedText(
        _ text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        var attributes = textAttributes(size: size, weight: weight, color: color)
        attributes[.paragraphStyle] = paragraph
        (text as NSString).draw(in: NSRect(x: x, y: y, width: width, height: 64), withAttributes: attributes)
    }

    private func textAttributes(size: CGFloat, weight: NSFont.Weight, color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
    }

    private func color(forRemaining remaining: Int) -> NSColor {
        if remaining <= 15 { return .systemRed }
        if remaining <= 35 { return .systemOrange }
        return .systemGreen
    }

    private var mutedColor: NSColor {
        NSColor(calibratedWhite: 0.66, alpha: 1)
    }

    private func formatTokens(_ value: Int64) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client = AppServerClient()
    private var panel: NSPanel!
    private var dashboard: DashboardView!
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        buildPanel()
        showPanel()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        client.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "Codex 用量")
            button.imagePosition = .imageLeading
            button.title = " Codex"
            button.target = self
            button.action = #selector(togglePanel)
        }
    }

    private func buildPanel() {
        dashboard = DashboardView(frame: NSRect(x: 0, y: 0, width: 340, height: 370))
        dashboard.refreshButton.target = self
        dashboard.refreshButton.action = #selector(refreshNow)
        dashboard.minimizeButton.target = self
        dashboard.minimizeButton.action = #selector(minimizePanel)
        dashboard.quitButton.target = self
        dashboard.quitButton.action = #selector(quit)

        panel = NSPanel(
            contentRect: dashboard.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = dashboard
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    @objc private func togglePanel() {
        panel.isVisible ? panel.orderOut(nil) : showPanel()
    }

    private func showPanel() {
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let origin = NSPoint(x: frame.maxX - panel.frame.width - 18, y: frame.maxY - panel.frame.height - 18)
            if !panel.isVisible { panel.setFrameOrigin(origin) }
        }
        panel.orderFrontRegardless()
    }

    @objc private func refreshNow() { refresh() }

    @objc private func minimizePanel() { panel.orderOut(nil) }

    private func refresh() {
        dashboard.isLoading = true
        client.fetch { [weak self] result in
            guard let self else { return }
            self.dashboard.isLoading = false
            switch result {
            case .success(let snapshot):
                self.dashboard.snapshot = snapshot
                self.dashboard.errorMessage = nil
                if let window = snapshot.fiveHour ?? snapshot.sevenDay {
                    let remaining = max(0, 100 - window.usedPercent)
                    self.statusItem.button?.title = " \(remaining)% · \(self.shortTokens(snapshot.todayTokens))"
                } else {
                    self.statusItem.button?.title = " 暂无数据"
                }
            case .failure(let error):
                self.dashboard.errorMessage = error.localizedDescription
                self.statusItem.button?.title = " 暂不可用"
            }
        }
    }

    private func shortTokens(_ value: Int64) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0fK", Double(value) / 1_000) }
        return "\(value)"
    }

    @objc private func quit() {
        let alert = NSAlert()
        alert.messageText = "完全退出 Codex 用量监控？"
        alert.informativeText = "退出后菜单栏图标会消失。你可以从“应用程序”重新打开，或在终端运行 codex-usage-monitor。若只是暂时隐藏，请使用“最小化”。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "完全退出")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSApp.terminate(nil)
        }
    }
}

@main
private enum CodexUsageMonitorMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
