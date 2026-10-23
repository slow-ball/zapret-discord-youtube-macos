import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case overview, strategies, sites, games, telegram, diagnostics, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Обзор"
        case .strategies: "Стратегии"
        case .sites: "Сайты"
        case .games: "Игры"
        case .telegram: "Telegram"
        case .diagnostics: "Диагностика"
        case .settings: "Настройки"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .strategies: "slider.horizontal.3"
        case .sites: "globe"
        case .games: "gamecontroller.fill"
        case .telegram: "paperplane.fill"
        case .diagnostics: "stethoscope"
        case .settings: "gearshape.fill"
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var page: Page = Page(rawValue: UserDefaults.standard.string(forKey: "page") ?? "") ?? .overview

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { p in
                Label(p.title, systemImage: p.symbol).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { sidebarStatus }
        } detail: {
            ScrollView {
                Group {
                    if !model.installed {
                        WelcomeView()
                    } else {
                        switch page {
                        case .overview: OverviewPage(page: $page)
                        case .strategies: StrategiesPage()
                        case .sites: SitesPage()
                        case .games: GamesPage()
                        case .telegram: TelegramPage()
                        case .diagnostics: DiagnosticsPage()
                        case .settings: SettingsPage()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(page.title)
            .overlay(alignment: .bottom) {
                if let t = model.toast { Toast(text: t).padding(.bottom, 20) }
            }
            .animation(Theme.spring, value: model.toast)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPage)) { n in
            if let raw = n.object as? String, let p = Page(rawValue: raw) { page = p }
        }
        .onChange(of: page) { _, p in UserDefaults.standard.set(p.rawValue, forKey: "page") }
        .onAppear {
            // a window of its own: show in the Dock while it is open, like a normal app
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            model.startPolling()
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
            model.stopPolling()
        }
    }

    private var sidebarStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.status.running ? Theme.ok : Color.gray)
                .frame(width: 8, height: 8)
                .shadow(color: model.status.running ? Theme.ok : .clear, radius: 4)
            Text(model.status.running ? "Работает" : "Остановлен")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            Spacer()
            Text(model.status.version).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
