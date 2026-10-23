import AppKit
import Foundation
import Observation
import ServiceManagement
import WidgetKit

struct Status: Decodable, Equatable {
    var version = ""
    var installed = false
    var running = false
    var strategy = ""
    var engine = "tpws"
    var scope = "all"
    var game = "off"
    var autostart = false
    var autofix = false
    var autoupdate = false
    var vpn = false
    var ipv6 = false
    var found = 0
    var sites = 0
    var project = ""
    var telegram = false
    var telegramRunning = false
    var telegramLink = ""
    var flowsealTelegram = false

    init() {}

    /// fields the script doesn't know yet keep their defaults: the root copy of the script
    /// may be older than the app, and one missing key must not throw the whole status away
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func get<T: Decodable>(_ key: Keys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        version = get(.version, version); installed = get(.installed, installed); running = get(.running, running)
        strategy = get(.strategy, strategy); engine = get(.engine, engine); scope = get(.scope, scope); game = get(.game, game)
        autostart = get(.autostart, autostart); autofix = get(.autofix, autofix); autoupdate = get(.autoupdate, autoupdate)
        vpn = get(.vpn, vpn); ipv6 = get(.ipv6, ipv6); found = get(.found, found); sites = get(.sites, sites)
        project = get(.project, project); telegram = get(.telegram, telegram); telegramRunning = get(.telegramRunning, telegramRunning)
        telegramLink = get(.telegramLink, telegramLink); flowsealTelegram = get(.flowsealTelegram, flowsealTelegram)
    }

    private enum Keys: String, CodingKey {
        case version, installed, running, strategy, engine, scope, game, autostart, autofix, autoupdate, vpn, ipv6
        case found, sites, project, telegram, telegramRunning, telegramLink, flowsealTelegram
    }
}

struct Strategy: Identifiable, Hashable {
    let name: String
    var id: String { name }
    var engine: String { name.hasPrefix("nfqws ") ? "nfqws" : "tpws" }
    /// name without the engine prefix: "general (ALT13)"
    var title: String { engine == "nfqws" ? String(name.dropFirst(6)) : name }
}

struct FoundSite: Decodable, Identifiable, Hashable {
    let site: String
    let strategy: String
    var id: String { site }
}

struct CheckResult: Identifiable, Equatable {
    let name: String
    let ok: Bool
    let kbps: Int
    let voice: Bool
    var id: String { name }
}

struct CheckRun: Equatable {
    var total = 0
    var results: [CheckResult] = []
    var baseline: String?
    var best: String?
    var finished = false
    var error: String?
    var progress: Double { total == 0 ? 0 : min(Double(results.count) / Double(total), 1) }
}

struct SiteResult: Decodable, Equatable {
    var site = ""
    var added = false
    var direct = false
    var works = false
    var strategy = ""
    var error: String?
}

struct DiagItem: Identifiable {
    enum Kind { case ok, bad, warn, info }
    let id = UUID()
    let kind: Kind
    let text: String
    /// a fix the script suggests for this line (@fix in diag --tags)
    var fix: String?
}

struct DiagSection: Identifiable {
    let id = UUID()
    let title: String
    var items: [DiagItem]
}

@Observable @MainActor
final class AppModel {
    static let shared = AppModel()

    var status = Status()
    var strategies: [Strategy] = []
    var found: [FoundSite] = []
    var youtube = Health.State.unknown
    var discord = Health.State.unknown
    var voice = Health.State.unknown
    var check: CheckRun?
    var diagnostics: [DiagSection] = []
    var diagRunning = false
    var diagError: String?
    var learning = false
    var busy = false
    var toast: String?
    var remoteVersion: String?
    var loginItem = SMAppService.mainApp.status == .enabled

    var installed: Bool { Shell.installed }
    var current: Strategy? { strategies.first { $0.name == status.strategy } }
    var updateAvailable: Bool {
        guard let r = remoteVersion, !status.version.isEmpty else { return false }
        return r.compare(status.version, options: .numeric) == .orderedDescending
    }

    private var lastHealth = Date.distantPast
    private var poller: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    /// changes right after our own actions are not news
    private var lastAction = Date.distantPast
    private var youtubeFails = 0
    private var notifiedVersion: String?

    init() {
        Task { await refresh() }
        if Snapshot.folder == nil { startMonitor() }
    }

    /// in the background, while the app runs: notices what happened without the user and tells about it
    private func startMonitor() {
        monitor = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self else { return }
                let before = self.status
                await self.refreshStatus()
                self.notifyChanges(from: before, to: self.status)
                // the widget's container may appear after the app started
                self.updateWidget()
                tick += 1
                // every 10 minutes: does YouTube still open?
                if tick % 30 == 0, self.status.running, !self.status.vpn, self.check?.finished != false {
                    await self.checkHealth(force: true)
                    self.youtubeFails = self.youtube == .fail ? self.youtubeFails + 1 : 0
                    if self.youtubeFails == 2 {
                        Notifier.send("YouTube не открывается", "Стратегия «\(self.current?.title ?? "")» перестала работать.", category: "broken")
                    }
                }
                // every 6 hours: a new version?
                if tick % 1080 == 1 {
                    await self.fetchRemoteVersion()
                    if self.updateAvailable, let v = self.remoteVersion, v != self.notifiedVersion {
                        self.notifiedVersion = v
                        Notifier.send("Доступна версия \(v)", "Свежие стратегии и исправления.", category: "update")
                    }
                }
            }
        }
    }

    private func notifyChanges(from old: Status, to new: Status) {
        guard !old.version.isEmpty, Date().timeIntervalSince(lastAction) > 15, check?.finished != false else { return }
        if old.running && !new.running {
            Notifier.send("zapret остановлен", "YouTube и Discord снова могут тормозить.", category: "stopped")
        } else if new.running, old.strategy != new.strategy, !old.strategy.isEmpty {
            // autofix picked another one
            let title = new.strategy.replacingOccurrences(of: "nfqws ", with: "")
            Notifier.send("Стратегия сменилась", "Автопочинка включила «\(title)».")
        }
        if old.version != new.version {
            Notifier.send("zapret обновлён", "Версия \(new.version).")
        }
    }

    /// keeps the status fresh while something is on screen
    func startPolling() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stopPolling() {
        poller?.cancel()
        poller = nil
    }

    func refresh() async {
        await refreshStatus()
        let list = await Shell.run(["list"])
        strategies = list.out.split(separator: "\n").map { Strategy(name: String($0)) }
        await refreshFound()
        await checkHealth(force: true)
        await fetchRemoteVersion()
    }

    /// screenshots for the README: a fixed state, no polling (Snapshot, ZAPRET_DEMO=1)
    var demo = false

    func refreshStatus() async {
        guard installed, !demo else { return }
        let r = await Shell.run(["status", "--json"])
        if let s = try? JSONDecoder().decode(Status.self, from: Data(r.out.utf8)), s != status {
            status = s
            updateWidget()
        }
    }

    /// set by the menu bar icon, the one view that always exists: opens the main window
    var openMainWindow: (() -> Void)?

    /// the widget is sandboxed: the app writes what it shows straight into its container
    func updateWidget() {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/com.zapret-macos.app.widget/Data/Library/Application Support")
        guard FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().path) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let info: [String: Any] = ["running": status.running, "strategy": status.strategy, "engine": status.engine,
                                   "youtube": youtube == .unknown || youtube == .checking ? NSNull() : youtube.isOK as Any,
                                   "discord": discord == .unknown || discord == .checking ? NSNull() : discord.isOK as Any]
        // reload only on changes: WidgetKit gives each widget a limited budget of reloads
        if let data = try? JSONSerialization.data(withJSONObject: info, options: .sortedKeys), data != widgetData {
            try? data.write(to: dir.appendingPathComponent("status.json"))
            widgetData = data
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private var widgetData: Data?

    func refreshFound() async {
        let r = await Shell.run(["found", "--json"])
        found = (try? JSONDecoder().decode([FoundSite].self, from: Data(r.out.utf8))) ?? []
    }

    func checkHealth(force: Bool = false) async {
        guard !demo, force || Date().timeIntervalSince(lastHealth) > 30 else { return }
        lastHealth = Date()
        youtube = .checking; discord = .checking; voice = .checking
        async let y = Health.youtube()
        async let d = Health.discord()
        async let v = Health.voice()
        youtube = await y
        discord = await d
        voice = await v
        updateWidget()
    }

    private func fetchRemoteVersion() async {
        let url = URL(string: "https://raw.githubusercontent.com/slow-ball/zapret-discord-youtube-macos/main/src/VERSION")!
        if let (data, _) = try? await URLSession.shared.data(from: url) {
            remoteVersion = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: actions

    /// a root command; before the passwordless rule exists (first start after an upgrade)
    /// the project's script runs once with the password dialog and installs it
    @discardableResult
    func privileged(_ args: [String], success: String? = nil) async -> Bool {
        lastAction = Date()
        busy = true
        defer { busy = false }
        var r = await Shell.run(args, root: true)
        if r.needsPassword, !status.project.isEmpty {
            r = await Shell.admin(status.project + "/src/zapret.sh", args)
        }
        await refreshStatus()
        if r.ok {
            if let success { show(success) }
        } else {
            show(r.err.split(separator: "\n").last.map(String.init) ?? "Не получилось")
        }
        return r.ok
    }

    func toggle() async {
        if status.running {
            await privileged(["stop"], success: "zapret остановлен")
        } else {
            await privileged(["start"], success: "zapret запущен")
        }
        await checkHealth(force: true)
    }

    func start(_ s: Strategy) async {
        await privileged(["start", s.name], success: "Включена \(s.title)")
        await checkHealth(force: true)
    }

    func setScope(_ v: String) async { await privileged(["scope", v]) }
    func setGame(_ v: String) async { await privileged(["game", v]) }
    func setAutostart(_ on: Bool) async { await privileged(["autostart", on ? "on" : "off"]) }
    func setAutofix(_ on: Bool) async { await privileged(["watchdog", on ? "on" : "off"]) }
    func setAutoupdate(_ on: Bool) async { await privileged(["autoupdate", on ? "on" : "off"]) }

    var telegramBusy = false
    var telegramCheck = Health.State.unknown

    /// the whole path: a handshake like Telegram Desktop's through the proxy, an answer from Telegram
    func testTelegram() async {
        telegramCheck = .checking
        let r = await Shell.run(["telegram", "test"])
        telegramCheck = r.ok ? .ok(nil) : .fail
    }

    func setTelegram(_ on: Bool) async {
        telegramBusy = true
        await privileged(["telegram", on ? "on" : "off"], success: on ? "Прокси для Telegram включён" : "Прокси для Telegram выключен")
        telegramBusy = false
    }

    /// one click from the menu bar: turns the proxy on if needed, then hands the link to Telegram
    func connectTelegramFully() async {
        if !status.telegram || !status.telegramRunning {
            await setTelegram(true)
            for _ in 0..<10 where !status.telegramRunning {
                try? await Task.sleep(for: .milliseconds(500))
                await refreshStatus()
            }
        }
        if status.telegramRunning { connectTelegram() }
    }

    /// Telegram Desktop adds the proxy itself from this link
    func connectTelegram() {
        guard let url = URL(string: status.telegramLink), !status.telegramLink.isEmpty else { return }
        NSWorkspace.shared.open(url)
    }

    func copyTelegramLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(status.telegramLink, forType: .string)
        show("Ссылка скопирована")
    }

    func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            show("Не получилось: \(error.localizedDescription)")
        }
        loginItem = SMAppService.mainApp.status == .enabled
    }

    func learn() async {
        learning = true
        await privileged(["learn"], success: "Стратегии для сайтов подобраны")
        await refreshFound()
        learning = false
    }

    func clearFound() async {
        await privileged(["found", "clear"], success: "Найденные сайты очищены")
        await refreshFound()
    }

    /// updates run the new script from the project folder, so always with the password dialog
    func update() async {
        guard !status.project.isEmpty else { return }
        busy = true
        let r = await Shell.admin(status.project + "/src/zapret.sh", ["update"])
        busy = false
        show(r.ok ? "Обновлено" : "Не получилось обновить")
        await refresh()
    }

    func runCheck(quick: Bool = false) async {
        guard check?.finished != false else { return }
        check = CheckRun()
        // the passwordless rule must exist: check streams its output, the password dialog can't
        let probe = await Shell.run(["found"], root: true)
        if probe.needsPassword, !status.project.isEmpty {
            _ = await Shell.admin(status.project + "/src/zapret.sh", ["start"])
        }
        let r = await Shell.stream(["check", "--json"] + (quick ? ["--quick"] : [])) { line in
            Task { @MainActor [weak self] in self?.handle(line) }
        }
        if !r.ok, check?.error == nil, check?.best == nil {
            check?.error = r.needsPassword ? "Нет прав: перезапустить стратегию" : "Подбор прервался"
        }
        check?.finished = true
        lastAction = Date()
        await refreshStatus()
        await checkHealth(force: true)
        // started from a notification or the hot key: the result is news too
        if !NSApp.isActive {
            if let best = check?.best {
                Notifier.send("Стратегия подобрана", "Включена «\(best.replacingOccurrences(of: "nfqws ", with: ""))».")
            } else {
                Notifier.send("Подбор не помог", check?.error ?? "Ни одна стратегия не прошла проверки.")
            }
        }
    }

    private func handle(_ line: String) {
        guard let data = line.data(using: .utf8),
              let e = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        switch e["event"] {
        case "start":
            check?.total = Int(e["total"] ?? "") ?? 0
        case "base":
            check?.baseline = e["pass"]
        case "result":
            check?.results.append(CheckResult(name: e["name"] ?? "", ok: e["ok"] == "1",
                                              kbps: Int(e["kbps"] ?? "") ?? 0, voice: e["voice"] == "1"))
        case "finish":
            check?.best = (e["best"] ?? "").isEmpty ? nil : e["best"]
            if check?.best == nil { check?.error = "Ни одна стратегия не прошла все проверки" }
        case "error":
            check?.error = e["message"]
        default:
            break
        }
    }

    func runDiagnostics() async {
        diagRunning = true
        diagError = nil
        var r = await Shell.run(["diag", "--tags"], root: true)
        if r.needsPassword, !status.project.isEmpty {
            r = await Shell.admin(status.project + "/src/zapret.sh", ["diag", "--tags"])
        }
        if r.out.isEmpty {
            diagError = r.err.isEmpty ? "Диагностика не запустилась" : r.err
        }
        var sections: [DiagSection] = []
        for raw in r.out.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if text.hasPrefix("@fix "), !sections.isEmpty, !sections[sections.count - 1].items.isEmpty {
                let s = sections.count - 1
                sections[s].items[sections[s].items.count - 1].fix = String(text.dropFirst(5))
                continue
            }
            if !line.hasPrefix(" ") {
                sections.append(DiagSection(title: text, items: []))
                continue
            }
            let kind: DiagItem.Kind
            switch text.first {
            case "✓": kind = .ok
            case "✗": kind = .bad
            case "!": kind = .warn
            default: kind = .info
            }
            let body = text.drop { "✓✗!· ".contains($0) }
            if sections.isEmpty { sections.append(DiagSection(title: "zapret", items: [])) }
            sections[sections.count - 1].items.append(DiagItem(kind: kind, text: String(body)))
        }
        diagnostics = sections
        diagRunning = false
    }

    // MARK: sites and lists

    var siteChecking = false
    var siteResult: SiteResult?

    /// a site that doesn't open: into the list, its own strategy if needed, checked like in a browser
    func checkSite(_ address: String) async {
        siteChecking = true
        siteResult = nil
        lastAction = Date()
        var r = await Shell.run(["site", address, "--json"], root: true)
        if r.needsPassword, !status.project.isEmpty {
            r = await Shell.admin(status.project + "/src/zapret.sh", ["site", address, "--json"])
        }
        siteResult = (try? JSONDecoder().decode(SiteResult.self, from: Data(r.out.utf8)))
            ?? SiteResult(error: r.err.isEmpty ? "Проверка не удалась" : r.err)
        siteChecking = false
        loadLists()
        await refreshStatus()
    }

    var mySites: [String] = []
    var myExclusions: [String] = []
    var listsChanged = false

    private func listURL(_ exclusions: Bool) -> URL? {
        status.project.isEmpty ? nil
            : URL(fileURLWithPath: status.project + "/lists/" + (exclusions ? "list-exclude-user.txt" : "list-user.txt"))
    }

    func loadLists() {
        func entries(_ url: URL?) -> [String] {
            guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        mySites = entries(listURL(false))
        myExclusions = entries(listURL(true))
    }

    /// the files keep their comment lines; zapret reads them on the next start
    private func saveList(_ exclusions: Bool) {
        guard let url = listURL(exclusions) else { return }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let comments = text.split(whereSeparator: \.isNewline).map(String.init).filter { $0.hasPrefix("#") }
        let body = (comments + (exclusions ? myExclusions : mySites)).joined(separator: "\n") + "\n"
        try? body.write(to: url, atomically: true, encoding: .utf8)
        listsChanged = true
    }

    func addToList(_ raw: String, exclusions: Bool) {
        var d = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if let r = d.range(of: "://") { d = String(d[r.upperBound...]) }
        d = String(d.prefix { !"/?#:".contains($0) })
        if d.hasPrefix("www.") { d.removeFirst(4) }
        guard d.contains("."), d.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else {
            show("Не похоже на адрес сайта")
            return
        }
        if exclusions {
            guard !myExclusions.contains(d) else { return }
            myExclusions.append(d)
        } else {
            guard !mySites.contains(d) else { return }
            mySites.append(d)
        }
        saveList(exclusions)
    }

    func removeFromList(_ d: String, exclusions: Bool) {
        if exclusions { myExclusions.removeAll { $0 == d } } else { mySites.removeAll { $0 == d } }
        saveList(exclusions)
    }

    func applyLists() async {
        await privileged(["start"], success: "Списки применены")
        listsChanged = false
    }

    static func fixTitle(_ code: String) -> String {
        switch code {
        case "start": "Запустить"
        case "restart": "Перезапустить"
        case "check": "Подобрать стратегию"
        case "update": "Обновить"
        case "telegram": "Перезапустить прокси"
        case "dns": "Поставить DNS 1.1.1.1"
        case "proxy-settings": "Настройки сети"
        case "monitor": "Мониторинг системы"
        case "quit-flowseal": "Закрыть TG WS Proxy"
        case "chrome-dns", "chrome-quic": "Открыть в Chrome"
        case "relay": "Настройки iCloud"
        default: "Исправить"
        }
    }

    /// the buttons of the diagnostics: fixes zapret can do itself, or the right settings page
    func applyFix(_ code: String) async {
        let ws = NSWorkspace.shared
        func chrome(_ page: String) {
            guard let app = ws.urlForApplication(withBundleIdentifier: "com.google.Chrome"), let url = URL(string: page) else { return }
            ws.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
        switch code {
        case "start", "restart": await privileged(["start"], success: "zapret перезапущен")
        case "check": await runCheck(); return
        case "update": await update(); return
        case "telegram": await setTelegram(true)
        case "dns": await privileged(["dns"], success: "DNS изменён")
        case "proxy-settings": ws.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!); return
        case "monitor":
            if let app = ws.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
                ws.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
            return
        case "quit-flowseal":
            ws.runningApplications.filter { $0.executableURL?.lastPathComponent == "TgWsProxy" }.forEach { $0.terminate() }
            try? await Task.sleep(for: .seconds(1))
        case "chrome-dns": chrome("chrome://settings/security"); return
        case "chrome-quic": chrome("chrome://flags/#enable-quic"); return
        case "relay": ws.open(URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings:icloud")!); return
        default: return
        }
        await runDiagnostics()
    }

    func openLists() {
        guard !status.project.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", status.project + "/lists/list-user.txt", status.project + "/lists/list-exclude-user.txt"]
        try? p.run()
    }

    var installing = false
    var installError: String?

    /// installs without Terminal: the project from inside the app goes to ~/zapret-macos
    /// (unless it is there already), then its installer runs with the password dialog
    func installZapret() async {
        installing = true
        installError = nil
        defer { installing = false }
        let dest = NSHomeDirectory() + "/zapret-macos"
        if !FileManager.default.fileExists(atPath: dest + "/src/zapret.sh") {
            guard let payload = Bundle.main.resourcePath.map({ $0 + "/project" }),
                  FileManager.default.fileExists(atPath: payload) else {
                installError = "В приложении нет файлов проекта"
                return
            }
            let copy = Process()
            copy.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            copy.arguments = [payload, dest]
            try? copy.run()
            copy.waitUntilExit()
            guard copy.terminationStatus == 0 else {
                installError = "Не удалось скопировать файлы в \(dest)"
                return
            }
        }
        let r = await Shell.admin(dest + "/src/zapret.sh", ["install", "--no-app"])
        if r.ok {
            await refresh()
            show("zapret установлен")
        } else if !r.err.contains("-128") && !r.err.localizedCaseInsensitiveContains("cancel") {
            installError = r.err.isEmpty ? "Установка не удалась" : r.err
        }
    }

    func installInTerminal() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Terminal", NSHomeDirectory() + "/zapret-macos/zapret.command"]
        try? p.run()
    }

    private var toastTask: Task<Void, Never>?

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { toast = nil }
        }
    }
}
