import SwiftUI

/// 850 КБ/с, 6,8 МБ/с
func speedText(_ kbps: Int) -> String {
    kbps < 1000 ? "\(kbps) КБ/с" : String(format: "%.1f МБ/с", Double(kbps) / 1024).replacingOccurrences(of: ".", with: ",")
}

// MARK: strategies

struct StrategiesPage: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Стратегии", subtitle: "Способы, которыми zapret обходит замедление. Какой работает у вашего провайдера, проще всего узнать автоподбором.")
            autopick
            if let run = model.check { CheckCard(run: run) }
            DeepCard()
            HStack {
                Text("Все стратегии").font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                TextField("Поиск", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            group("nfqws", "Стратегии Windows-версии: фейковые пакеты, QUIC и UDP")
            group("tpws", "Разбиение пакетов, IPv4 и IPv6")
        }
    }

    private var autopick: some View {
        HStack(spacing: 18) {
            Image(systemName: "wand.and.stars").font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("Автоподбор").font(.system(size: 20, weight: .heavy, design: .rounded))
                Text("Проверит YouTube, Discord и голос для всех 37 стратегий и включит лучшую. Около двух минут, интернет может пропадать.")
                    .font(.system(size: 12)).opacity(0.85).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.white)
            Spacer(minLength: 8)
            VStack(spacing: 8) {
                Button("Подобрать") { Task { await model.runCheck() } }
                    .buttonStyle(PillButtonStyle(tint: .white.opacity(0.95), text: Theme.glow))
                Button("Только tpws, быстро") { Task { await model.runCheck(quick: true) } }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            }
            .disabled(model.check?.finished == false)
        }
        .padding(20)
        .background(Theme.aurora, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Theme.glow.opacity(0.3), radius: 18, y: 8)
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

/// When no strategy helps: blockcheck of bol-van, hundreds of options for one site
struct DeepCard: View {
    @Environment(AppModel.self) private var model
    @State private var site = "www.youtube.com"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                IconTile(symbol: "scope", gradient: LinearGradient(colors: [Color.indigo.opacity(0.8), .indigo], startPoint: .top, endPoint: .bottom), size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ничего не помогло?").font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Глубокий подбор переберёт сотни вариантов для одного сайта и сохранит найденный как вашу стратегию. 5–15 минут, интернет может пропадать.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let run = model.deep, !run.finished {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Проверено вариантов: \(run.tested)").font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                if !run.option.isEmpty {
                    Text(run.option).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                HStack {
                    TextField("сайт", text: $site).textFieldStyle(.roundedBorder)
                    Button("Глубокий подбор") { Task { await model.runDeep(site) } }
                        .buttonStyle(PillButtonStyle(tint: .indigo))
                        .disabled(site.isEmpty || model.check?.finished == false)
                }
                if let run = model.deep { result(run) }
            }
        }
        .padding(16)
        .glassCard()
        .animation(Theme.spring, value: model.deep)
    }

    @ViewBuilder private func result(_ run: DeepRun) -> some View {
        if let e = run.error {
            Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn).font(.system(size: 13))
        } else if let s = run.strategy {
            Label("Найдено и включено: \(s)", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.ok)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
        } else if run.reason == "open" {
            Label("\(run.site) открывается и без обхода — дело не в провайдере", systemImage: "info.circle.fill")
                .foregroundStyle(.secondary).font(.system(size: 13))
        } else {
            Label("Ничего не нашлось: провайдер режет этот сайт так, что tpws не помогает. Попробуйте стратегии nfqws.",
                  systemImage: "xmark.circle.fill").foregroundStyle(Theme.bad).font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
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
                        Text(speedText(r.kbps)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    } else {
                        Text("не работает").font(.system(size: 12)).foregroundStyle(Theme.bad)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(hover && Snapshot.folder == nil ? Color.primary.opacity(0.05) : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                            Text(speedText(r.kbps)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
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
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Сайты", subtitle: "Какие сайты обрабатывает zapret и что делать, если какой-то не открывается.")
            HStack(spacing: 12) {
                ScopeCard(value: "all", symbol: "globe", title: "Все сайты", text: "Всё, кроме исключений")
                ScopeCard(value: "smart", symbol: "sparkle.magnifyingglass", title: "Умный", text: "Только то, что не открывается без обхода")
                ScopeCard(value: "lists", symbol: "list.bullet", title: "По спискам", text: "YouTube, Discord и свои сайты")
            }
            .fixedSize(horizontal: false, vertical: true)
            SiteCheckCard()
            // only the smart mode finds sites
            if model.status.scope == "smart" || !model.found.isEmpty {
                HStack {
                    Text("Найденные сайты").font(.system(size: 20, weight: .bold, design: .rounded))
                    Spacer()
                    Button { Task { await model.learn() } } label: {
                        if model.learning { ProgressView().controlSize(.small) } else { Label("Подобрать стратегии", systemImage: "wand.and.stars") }
                    }
                    .disabled(model.found.isEmpty || model.learning)
                    Button("Очистить", role: .destructive) { Task { await model.clearFound() } }.disabled(model.found.isEmpty)
                }
                if model.found.isEmpty {
                    Card {
                        Text("Пока ничего: сайты появятся здесь, когда не откроются без обхода.")
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

}

/// One of the three scopes, as a selectable card
struct ScopeCard: View {
    @Environment(AppModel.self) private var model
    let value: String
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        let selected = model.status.scope == value
        Button { Task { await model.setScope(value) } } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.aurora))
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                }
                Text(title).font(.system(size: 15, weight: .bold, design: .rounded))
                Text(text).font(.system(size: 12)).opacity(selected ? 0.9 : 0.6).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.aurora)
                } else {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.primary.opacity(0.045))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(selected ? 0 : 0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Theme.spring, value: selected)
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

// MARK: diagnostics

struct DiagnosticsPage: View {
    @Environment(AppModel.self) private var model
    @State private var reportSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Проверка", subtitle: "zapret проверит себя, сеть и браузеры. Если что-то не так — рядом будет кнопка, чтобы исправить.")
            summary
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
        .sheet(isPresented: $reportSheet) { ReportSheet() }
    }

    private var summary: some View {
        let problems = model.diagnostics.flatMap(\.items).filter { $0.kind == .bad || $0.kind == .warn }.count
        let ok = problems == 0 && !model.diagnostics.isEmpty
        let idle = model.diagRunning || model.diagnostics.isEmpty
        return HStack(spacing: 18) {
            Image(systemName: idle ? "stethoscope" : ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .symbolEffect(.pulse, isActive: model.diagRunning)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.diagRunning ? "Проверяю…" : model.diagnostics.isEmpty ? "Проверка" : ok ? "Всё в порядке" : "Есть что исправить: \(problems)")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                Text(idle ? "Около 15 секунд" : ok ? "zapret, сеть и сервисы в порядке" : "Кнопки «Исправить» — рядом с проблемами")
                    .font(.system(size: 12)).opacity(0.85)
            }
            .foregroundStyle(.white)
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
            Button(model.diagnostics.isEmpty ? "Проверить" : "Проверить снова") { Task { await model.runDiagnostics() } }
                .buttonStyle(PillButtonStyle(tint: .white.opacity(0.95), text: ok ? Theme.ok : Theme.glow))
                .disabled(model.diagRunning)
            Button("Сообщить о проблеме") { reportSheet = true }
                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(20)
        .background(ok ? AnyShapeStyle(LinearGradient(colors: [Theme.ok.opacity(0.9), Color(red: 0.1, green: 0.65, blue: 0.55)],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                       : AnyShapeStyle(Theme.aurora),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(Theme.spring, value: ok)
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


/// The report before it goes anywhere: the user sees and may edit every line
struct ReportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var report = ""
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                IconTile(symbol: "ladybug.fill", gradient: LinearGradient(colors: [Color.orange.opacity(0.85), .orange], startPoint: .top, endPoint: .bottom), size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Сообщить о проблеме").font(.system(size: 22, weight: .heavy, design: .rounded))
                    Text("Откроется форма на GitHub с этим отчётом — останется указать провайдера и что не работает.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Label("Адреса IP, имя пользователя и компьютера, пути заменены. Свои списки сайтов в отчёт не попадают. Текст можно поправить.",
                  systemImage: "lock.shield.fill")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ok).fixedSize(horizontal: false, vertical: true)
            ZStack {
                TextEditor(text: $report)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .glassCard()
                if loading { ProgressView("Собираю отчёт…").controlSize(.small) }
            }
            .frame(height: 300)
            HStack {
                Button("Скопировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                    model.show("Отчёт скопирован")
                }
                .buttonStyle(PillButtonStyle(tint: .gray))
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Открыть на GitHub") {
                    model.openIssue(report)
                    dismiss()
                }
                .buttonStyle(PillButtonStyle())
                .disabled(loading)
            }
        }
        .padding(26)
        .frame(width: 620)
        .task {
            report = await model.buildReport()
            loading = false
        }
    }
}
