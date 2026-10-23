import SwiftUI

// MARK: overview

struct OverviewPage: View {
    @Environment(AppModel.self) private var model
    @Binding var page: Page

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            hero
            if model.updateAvailable, let v = model.remoteVersion {
                Card {
                    HStack {
                        Label("Доступна версия \(v)", systemImage: "sparkles").font(.system(size: 14, weight: .semibold, design: .rounded))
                        Spacer()
                        Button("Обновить") { Task { await model.update() } }.buttonStyle(.borderedProminent).tint(Theme.glow)
                    }
                }
            }
            HStack(spacing: 10) {
                HealthPill(title: "YouTube", symbol: "play.rectangle.fill", state: model.youtube)
                HealthPill(title: "Discord", symbol: "bubble.left.and.bubble.right.fill", state: model.discord)
                HealthPill(title: "Голос Discord", symbol: "waveform", state: model.voice)
                Button { Task { await model.checkHealth(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Проверить ещё раз")
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                tile("Стратегия", model.current?.title ?? "—", "slider.horizontal.3", .strategies)
                tile("Сайты", ["all": "Все", "smart": "Умный режим", "lists": "По спискам"][model.status.scope] ?? "", "globe", .sites)
                tile("Игры", ["off": "Выключено", "tcp": "TCP", "udp": "UDP", "all": "TCP и UDP"][model.status.game] ?? "", "gamecontroller.fill", .games)
                tile("Найдено сайтов", "\(model.status.found)", "sparkle.magnifyingglass", .sites)
            }
        }
    }

    private var hero: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(model.status.running ? Theme.aurora : Theme.idle)
                .opacity(model.status.running ? 1 : 0.5)
            HStack(spacing: 24) {
                PowerButton(on: model.status.running, busy: model.busy, size: 104, onGradient: true) { Task { await model.toggle() } }
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.status.running ? "zapret работает" : "zapret остановлен")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .contentTransition(.interpolate)
                    if let s = model.current {
                        Text("\(s.title) · \(s.engine)").font(.system(size: 15, weight: .medium))
                    }
                    if model.status.vpn {
                        Label("Включён VPN — трафик идёт через него", systemImage: "network.badge.shield.half.filled")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
            }
            .padding(26)
        }
        .frame(height: 170)
        .shadow(color: model.status.running ? Theme.glow.opacity(0.35) : .clear, radius: 24, y: 10)
        .animation(Theme.spring, value: model.status.running)
    }

    private func tile(_ title: String, _ value: String, _ symbol: String, _ target: Page) -> some View {
        Button { page = target } label: {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.aurora)
                    Text(title).sectionTitle()
                    Text(value).font(.system(size: 17, weight: .bold, design: .rounded)).lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: strategies

struct StrategiesPage: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Автоподбор проверяет YouTube, Discord и голос в Discord для каждой стратегии и включает лучшую. tpws проверяются параллельно за секунды, nfqws по очереди, около двух минут — интернет на это время может пропадать.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { Task { await model.runCheck() } } label: {
                    Label("Подобрать автоматически", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent).tint(Theme.glow).controlSize(.large)
                Button("Только tpws") { Task { await model.runCheck(quick: true) } }
                    .buttonStyle(.bordered).controlSize(.large)
            }
            .disabled(model.check?.finished == false)
            if let run = model.check { CheckCard(run: run) }
            TextField("Поиск", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            group("nfqws", "Стратегии Windows-версии: фейковые пакеты, QUIC и UDP")
            group("tpws", "Разбиение пакетов, IPv4 и IPv6")
        }
    }

    private func group(_ engine: String, _ subtitle: String) -> some View {
        let items = model.strategies.filter { $0.engine == engine && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack { EngineBadge(engine: engine); Text(subtitle).sectionTitle() }
            Card(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(items) { s in
                        StrategyRow(strategy: s, result: model.check?.results.first { $0.name == s.name })
                        if s != items.last { Divider().padding(.leading, 12) }
                    }
                }
            }
        }
    }
}

struct StrategyRow: View {
    @Environment(AppModel.self) private var model
    let strategy: Strategy
    let result: CheckResult?
    @State private var hover = false

    var body: some View {
        let current = strategy.name == model.status.strategy
        Button { Task { await model.start(strategy) } } label: {
            HStack(spacing: 10) {
                Image(systemName: current ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(current ? AnyShapeStyle(Theme.aurora) : AnyShapeStyle(.tertiary))
                    .font(.system(size: 16))
                Text(strategy.title).font(.system(size: 13, weight: current ? .semibold : .regular))
                Spacer()
                if let r = result {
                    if r.ok {
                        Image(systemName: r.voice ? "waveform" : "waveform.slash")
                            .foregroundStyle(r.voice ? Theme.ok : Color.secondary).help(r.voice ? "Голос в Discord работает" : "Голос в Discord не работает")
                        Text("\(r.kbps) КБ/с").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    } else {
                        Text("не работает").font(.system(size: 12)).foregroundStyle(Theme.bad)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(hover ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct CheckCard: View {
    let run: CheckRun

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    if run.finished {
                        if let best = run.best {
                            Label("Включена \(best.replacingOccurrences(of: "nfqws ", with: ""))", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(Theme.ok)
                        } else {
                            Label(run.error ?? "Не получилось", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.bad)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Проверено \(run.results.count) из \(run.total)")
                    }
                    Spacer()
                    if let b = run.baseline { Text("без zapret: \(b)").font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                ProgressView(value: run.finished ? 1 : run.progress).tint(Theme.glow)
                    .animation(Theme.spring, value: run.progress)
                let working = run.results.filter(\.ok).sorted { ($0.voice ? 1 : 0, $0.kbps) > ($1.voice ? 1 : 0, $1.kbps) }
                if !working.isEmpty {
                    let top = working.prefix(5)
                    let max = Double(top.map(\.kbps).max() ?? 1)
                    ForEach(top) { r in
                        HStack(spacing: 8) {
                            Text(r.name.replacingOccurrences(of: "nfqws ", with: "")).font(.system(size: 12)).frame(width: 190, alignment: .leading)
                            GeometryReader { g in
                                Capsule().fill(Theme.aurora).frame(width: max > 0 ? g.size.width * Double(r.kbps) / max : 0)
                            }
                            .frame(height: 6)
                            Text("\(r.kbps)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
                            Image(systemName: r.voice ? "waveform" : "waveform.slash").foregroundStyle(r.voice ? Theme.ok : Color.secondary)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .animation(Theme.spring, value: run.results.count)
        }
    }
}

// MARK: sites

struct SitesPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let scope = Binding(get: { model.status.scope }, set: { v in Task { await model.setScope(v) } })
        VStack(alignment: .leading, spacing: 18) {
            Picker("", selection: scope) {
                Text("Все").tag("all")
                Text("Умный").tag("smart")
                Text("По спискам").tag("lists")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Card {
                Label(description, systemImage: symbol).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
            SiteCheckCard()
            HStack {
                Text("Найденные сайты").font(.system(size: 18, weight: .bold, design: .rounded))
                Spacer()
                Button { Task { await model.learn() } } label: {
                    if model.learning { ProgressView().controlSize(.small) } else { Label("Подобрать стратегии", systemImage: "wand.and.stars") }
                }
                .disabled(model.found.isEmpty || model.learning)
                Button("Очистить", role: .destructive) { Task { await model.clearFound() } }.disabled(model.found.isEmpty)
            }
            if model.found.isEmpty {
                Card {
                    Text(model.status.scope == "smart" ? "Пока ничего: сайты появятся здесь, когда не откроются без обхода." : "Умный режим выключен.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            } else {
                Card(padding: 6) {
                    VStack(spacing: 0) {
                        ForEach(model.found) { f in
                            HStack {
                                Image(systemName: "globe").foregroundStyle(.secondary)
                                Text(f.site).font(.system(size: 13, weight: .medium))
                                Spacer()
                                if !f.strategy.isEmpty {
                                    Text(f.strategy).font(.system(size: 11, weight: .semibold, design: .rounded))
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Theme.glow.opacity(0.15), in: Capsule())
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            if f != model.found.last { Divider().padding(.leading, 12) }
                        }
                    }
                }
            }
            ListEditor(title: "Мои сайты", subtitle: "Обрабатываются в любом режиме, вместе с YouTube и Discord", exclusions: false)
            ListEditor(title: "Исключения", subtitle: "Эти сайты zapret никогда не трогает", exclusions: true)
            HStack {
                if model.listsChanged {
                    Button { Task { await model.applyLists() } } label: { Label("Применить изменения", systemImage: "checkmark") }
                        .buttonStyle(.borderedProminent).tint(Theme.glow)
                }
                Spacer()
                Button("Открыть файлы в редакторе") { model.openLists() }.buttonStyle(.link)
            }
        }
        .task {
            await model.refreshFound()
            model.loadLists()
        }
    }

    private var description: String {
        switch model.status.scope {
        case "smart": "Обрабатываются YouTube, Discord, свои списки и сайты, которые сами не открылись: zapret замечает их после двух неудачных попыток. Остальные сайты не трогаются."
        case "lists": "Обрабатываются только YouTube, Discord и домены из своих списков."
        default: "Обрабатываются все сайты, кроме исключений."
        }
    }

    private var symbol: String {
        switch model.status.scope {
        case "smart": "sparkle.magnifyingglass"
        case "lists": "list.bullet"
        default: "globe"
        }
    }
}

struct SiteCheckCard: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Сайт не открывается?", systemImage: "questionmark.app.dashed")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("Адрес попадёт в «Мои сайты», для него подберётся своя стратегия, если основная его не открывает, и zapret проверит его так, как открывает браузер.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("например, example.com", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { check() }
                    Button { check() } label: {
                        if model.siteChecking { ProgressView().controlSize(.small).frame(width: 70) } else { Text("Проверить").frame(width: 70) }
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.glow)
                    .disabled(address.isEmpty || model.siteChecking)
                }
                if let r = model.siteResult { result(r) }
            }
        }
        .animation(Theme.spring, value: model.siteResult)
    }

    private func check() {
        guard !address.isEmpty else { return }
        Task { await model.checkSite(address) }
    }

    @ViewBuilder private func result(_ r: SiteResult) -> some View {
        if let e = r.error {
            Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn).font(.system(size: 13))
        } else if r.works {
            VStack(alignment: .leading, spacing: 4) {
                Label("\(r.site) открывается", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                if r.direct {
                    Text("Он открывается и без обхода — если в браузере не работает, дело не в провайдере: попробуйте перезапустить браузер.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else if !r.strategy.isEmpty {
                    Text("Для него включена своя стратегия: \(r.strategy)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("\(r.site) всё ещё не открывается", systemImage: "xmark.circle.fill").foregroundStyle(Theme.bad)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(r.direct ? "Без обхода он открывается — возможно, сайту мешает сама стратегия: добавьте его в исключения."
                              : "Можно подобрать другую основную стратегию: автоподбор проверит все.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if r.direct {
                    Button("В исключения") { model.addToList(r.site, exclusions: true) }
                } else {
                    Button("Подобрать стратегию") { Task { await model.runCheck() } }
                }
            }
        }
    }
}

struct ListEditor: View {
    @Environment(AppModel.self) private var model
    let title: String
    let subtitle: String
    let exclusions: Bool
    @State private var input = ""

    var body: some View {
        let items = exclusions ? model.myExclusions : model.mySites
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 18, weight: .bold, design: .rounded))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Card(padding: 8) {
                VStack(spacing: 0) {
                    ForEach(items, id: \.self) { d in
                        HStack {
                            Image(systemName: exclusions ? "nosign" : "globe").foregroundStyle(.secondary)
                            Text(d).font(.system(size: 13))
                            Spacer()
                            Button { model.removeFromList(d, exclusions: exclusions) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain).help("Убрать")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        Divider().padding(.leading, 8)
                    }
                    HStack {
                        TextField(exclusions ? "Добавить исключение" : "Добавить сайт", text: $input)
                            .textFieldStyle(.plain)
                            .onSubmit(add)
                        Button("Добавить", action: add).disabled(input.isEmpty)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                }
            }
        }
    }

    private func add() {
        model.addToList(input, exclusions: exclusions)
        input = ""
    }
}

// MARK: games

struct GamesPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let game = Binding(get: { model.status.game }, set: { v in Task { await model.setGame(v) } })
        VStack(alignment: .leading, spacing: 18) {
            Picker("", selection: game) {
                Text("Выключено").tag("off")
                Text("TCP").tag("tcp")
                Text("UDP").tag("udp")
                Text("TCP и UDP").tag("all")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Как Game Filter в Windows-версии", systemImage: "gamecontroller.fill").font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text("Обход работает и для портов 1024–65535 серверов игр и облачных сервисов. Если игра не подключается — включить UDP, если не помогло — TCP и UDP.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            if model.status.engine == "tpws" && model.status.game != "off" {
                Label("Работает только со стратегиями nfqws", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
            }
        }
    }
}

// MARK: telegram

struct TelegramPage: View {
    @Environment(AppModel.self) private var model

    /// 127.0.0.1:port from the link the script gives
    private var port: String {
        URLComponents(string: model.status.telegramLink)?.queryItems?.first { $0.name == "port" }?.value.map { "127.0.0.1:\($0)" } ?? "127.0.0.1"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                HStack(alignment: .top, spacing: 16) {
                    ZStack {
                        Circle().fill(LinearGradient(colors: [Color(red: 0.16, green: 0.67, blue: 0.94), Color(red: 0.13, green: 0.53, blue: 0.86)],
                                                     startPoint: .top, endPoint: .bottom))
                        Image(systemName: "paperplane.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white).offset(x: -1, y: 1)
                    }
                    .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Прокси для Telegram Desktop").font(.system(size: 17, weight: .bold, design: .rounded))
                        Text("Локальный MTProto-прокси: Telegram подключается к нему, а он передаёт трафик через WebSocket на веб-серверы Telegram. Данные остаются зашифрованными, сторонние серверы не нужны.")
                            .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if model.telegramBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Toggle("Прокси для Telegram", isOn: Binding(get: { model.status.telegram },
                                                                     set: { v in Task { await model.setTelegram(v) } }))
                            .labelsHidden().toggleStyle(.switch).tint(Theme.glow)
                    }
                }
            }
            if model.status.telegram {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(model.status.telegramRunning ? "Прокси работает: \(port)" : "Прокси не запущен",
                                  systemImage: model.status.telegramRunning ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(model.status.telegramRunning ? Theme.ok : Theme.warn)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                            Spacer()
                            if !model.status.telegramRunning {
                                Button("Перезапустить прокси") { Task { await model.setTelegram(true) } }
                                    .buttonStyle(.borderedProminent).tint(Theme.warn).disabled(model.telegramBusy)
                            }
                        }
                        Text("Нажать «Подключить Telegram» — Telegram Desktop откроется и предложит добавить прокси. Достаточно один раз.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button { model.connectTelegram() } label: { Label("Подключить Telegram", systemImage: "link") }
                                .buttonStyle(.borderedProminent).tint(Theme.glow).controlSize(.large)
                            Button("Скопировать ссылку") { model.copyTelegramLink() }.controlSize(.large)
                            Spacer()
                            Button { Task { await model.testTelegram() } } label: {
                                switch model.telegramCheck {
                                case .checking: ProgressView().controlSize(.small)
                                case .ok: Label("Telegram отвечает", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                                case .fail: Label("Не отвечает", systemImage: "xmark.circle.fill").foregroundStyle(Theme.bad)
                                case .unknown: Label("Проверить связь", systemImage: "antenna.radiowaves.left.and.right")
                                }
                            }
                            .controlSize(.large)
                            .help("Проверяет весь путь: рукопожатие как у Telegram через прокси и ответ сервера Telegram")
                        }
                        if model.status.flowsealTelegram {
                            Label("Запущено приложение TG WS Proxy от Flowseal — его лучше закрыть, прокси уже встроен",
                                  systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn).font(.system(size: 12, weight: .medium))
                        }
                    }
                }
            }
            Text("Прокси — tg-ws-proxy от Flowseal (MIT). Работает от пользователя nobody, без прав администратора.")
                .font(.system(size: 12)).foregroundStyle(.tertiary)
        }
    }
}

// MARK: diagnostics

struct DiagnosticsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { Task { await model.runDiagnostics() } } label: {
                if model.diagRunning { ProgressView().controlSize(.small) } else { Label("Проверить", systemImage: "stethoscope") }
            }
            .buttonStyle(.borderedProminent).tint(Theme.glow).controlSize(.large).disabled(model.diagRunning)
            if let e = model.diagError {
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
            }
            ForEach(model.diagnostics.filter { !$0.items.isEmpty }) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.title).sectionTitle()
                    Card(padding: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(section.items) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    icon(item.kind)
                                    Text(item.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 8)
                                    if let fix = item.fix {
                                        Button(AppModel.fixTitle(fix)) { Task { await model.applyFix(fix) } }
                                            .controlSize(.small)
                                            .buttonStyle(.borderedProminent)
                                            .tint(item.kind == .info ? Color.gray : Theme.glow)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .task { if model.diagnostics.isEmpty { await model.runDiagnostics() } }
    }

    @ViewBuilder private func icon(_ kind: DiagItem.Kind) -> some View {
        switch kind {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
        case .bad: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.bad)
        case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
        case .info: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}

// MARK: settings

struct SettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var hotkey = HotKey.enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    toggle("Открывать приложение при входе", "Иконка в строке меню после перезагрузки", model.loginItem) { model.setLoginItem($0) }
                    Divider()
                    toggle("Запускать zapret при загрузке", "Обход работает сразу после включения мака", model.status.autostart) { v in Task { await model.setAutostart(v) } }
                    Divider()
                    toggle("Автопочинка", "Каждые 5 минут проверяет YouTube и сама меняет стратегию, если он отвалился", model.status.autofix) { v in Task { await model.setAutofix(v) } }
                    Divider()
                    toggle("Автообновление", "Раз в сутки ставит новую версию со свежими стратегиями", model.status.autoupdate) { v in Task { await model.setAutoupdate(v) } }
                    Divider()
                    toggle("Горячая клавиша ⌃⌥Z", "Включает и выключает zapret из любого приложения", hotkey) { v in
                        HotKey.enabled = v
                        hotkey = v
                    }
                }
            }
            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Версия \(model.status.version)").font(.system(size: 15, weight: .semibold, design: .rounded))
                        Text(model.updateAvailable ? "Доступна \(model.remoteVersion ?? "")" : "Последняя версия").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Обновить") { Task { await model.update() } }.disabled(!model.updateAvailable)
                }
            }
            Text("Движки: tpws из zapret от bol-van, nfqws из порта Flowseal. Стратегии nfqws — из Windows-версии Flowseal.")
                .font(.system(size: 12)).foregroundStyle(.tertiary)
        }
    }

    private func toggle(_ title: String, _ subtitle: String, _ value: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: Binding(get: { value }, set: set))
                .labelsHidden().toggleStyle(.switch).tint(Theme.glow)
        }
    }
}
