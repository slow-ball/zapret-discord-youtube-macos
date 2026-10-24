import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case home, strategies, sites, diagnostics, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Главная"
        case .strategies: "Стратегии"
        case .sites: "Сайты"
        case .diagnostics: "Проверка"
        case .settings: "Настройки"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .strategies: "wand.and.stars"
        case .sites: "globe"
        case .diagnostics: "stethoscope"
        case .settings: "gearshape.fill"
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var page: Page = Page(rawValue: UserDefaults.standard.string(forKey: "page") ?? "") ?? .home

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    LogoMark(size: 20)
                    Text("zapret").font(.system(size: 17, weight: .heavy, design: .rounded))
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 10)
                List(Page.allCases, selection: $page) { p in
                    Label(p.title, systemImage: p.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.vertical, 3)
                        .tag(p)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { sidebarStatus }
        } detail: {
            ZStack(alignment: .top) {
                // the color of the state at the top, like an album cover behind a playlist
                LinearGradient(colors: glowColors, startPoint: .top, endPoint: .bottom)
                    .frame(height: 340)
                    .ignoresSafeArea(edges: .top)
                    .animation(.easeInOut(duration: 0.8), value: model.status.running)
                ScrollView {
                    Group {
                        if !model.installed {
                            WelcomeView()
                        } else {
                            switch page {
                            case .home: HomePage(page: $page)
                            case .strategies: StrategiesPage()
                            case .sites: SitesPage()
                            case .diagnostics: DiagnosticsPage()
                            case .settings: SettingsPage()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 36)
                    .padding(.top, 12)
                    .padding(.bottom, 36)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollContentBackground(.hidden)
            }
            .background(.background)
            .navigationTitle("")
            .toolbarBackground(.hidden, for: .windowToolbar)
            .overlay(alignment: .bottom) {
                if let t = model.toast { Toast(text: t).padding(.bottom, 20) }
            }
            .animation(Theme.spring, value: model.toast)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPage)) { n in
            if let raw = n.object as? String, let p = Page(rawValue: raw) { page = p }
        }
        .onReceive(NotificationCenter.default.publisher(for: .recheck)) { _ in
            Task {
                if page == .diagnostics { await model.runDiagnostics() } else { await model.checkHealth(force: true) }
            }
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

    private var glowColors: [Color] {
        model.status.running
            ? [Theme.glow.opacity(0.28), Theme.auroraColors[2].opacity(0.10), .clear]
            : [Color.gray.opacity(0.14), .clear]
    }

    private var sidebarStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.status.running ? Theme.ok : Color.gray)
                .frame(width: 8, height: 8)
                .shadow(color: model.status.running ? Theme.ok : .clear, radius: 4)
            Text(model.status.running ? "Работает" : "Выключен")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            Spacer()
            Text(model.status.version).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
