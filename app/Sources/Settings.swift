import SwiftUI

/// Settings in the manner of System Settings: grouped rows with colored icon tiles
struct SettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var hotkey = HotKey.enabled
    @State private var telegramSheet = false
    @State private var confirmUninstall = false

    var body: some View {
        let s = model.status
        VStack(alignment: .leading, spacing: 26) {
            PageHeader(title: "Настройки")
            SettingsGroup(title: "Запуск") {
                SettingsRow(symbol: "power", tint: .green, title: "Запускать zapret при загрузке",
                            text: "Обход работает сразу после включения мака") {
                    toggle(s.autostart) { v in Task { await model.setAutostart(v) } }
                }
                SettingsRow(symbol: "macwindow", tint: .blue, title: "Открывать приложение при входе",
                            text: "Иконка в строке меню после перезагрузки") {
                    toggle(model.loginItem) { model.setLoginItem($0) }
                }
                SettingsRow(symbol: "command", tint: .gray, title: "Горячая клавиша ⌃⌥Z",
                            text: "Включает и выключает zapret из любого приложения", last: true) {
                    toggle(hotkey) { v in HotKey.enabled = v; hotkey = v }
                }
            }
            SettingsGroup(title: "Автоматически") {
                SettingsRow(symbol: "arrow.triangle.2.circlepath", tint: .orange, title: "Автопочинка",
                            text: "Каждые 5 минут проверяет YouTube и сама меняет стратегию, если он отвалился") {
                    toggle(s.autofix) { v in Task { await model.setAutofix(v) } }
                }
                SettingsRow(symbol: "arrow.down.circle", tint: .purple, title: "Автообновление",
                            text: "Раз в сутки ставит новую версию со свежими стратегиями", last: true) {
                    toggle(s.autoupdate) { v in Task { await model.setAutoupdate(v) } }
                }
            }
            SettingsGroup(title: "Сервисы") {
                SettingsRow(symbol: "paperplane.fill", tint: Theme.telegram, title: "Прокси для Telegram",
                            text: s.telegram ? (s.telegramRunning ? "Работает" : "Не запущен") : "Выключен") {
                    Button("Настроить…") { telegramSheet = true }.buttonStyle(PillButtonStyle(tint: .gray))
                }
                SettingsRow(symbol: "gamecontroller.fill", tint: .pink, title: "Игры",
                            text: "Как Game Filter в Windows-версии: порты 1024–65535 серверов игр. Только nfqws", last: true) {
                    Picker("Игры", selection: Binding(get: { s.game }, set: { v in Task { await model.setGame(v) } })) {
                        Text("Выкл").tag("off")
                        Text("TCP").tag("tcp")
                        Text("UDP").tag("udp")
                        Text("Оба").tag("all")
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
            }
            SettingsGroup(title: "О программе") {
                SettingsRow(symbol: "info.circle.fill", tint: Theme.glow, title: "zapret \(s.version)",
                            text: model.updateAvailable ? "Доступна версия \(model.remoteVersion ?? "")" : "Последняя версия") {
                    if model.updateAvailable {
                        Button("Обновить") { Task { await model.update() } }.buttonStyle(PillButtonStyle())
                    }
                }
                SettingsRow(symbol: "chevron.left.forwardslash.chevron.right", tint: .gray, title: "Исходный код",
                            text: "Движки: zapret от bol-van, nfqws и tg-ws-proxy от Flowseal", last: true) {
                    Link("GitHub", destination: URL(string: "https://github.com/slow-ball/zapret-discord-youtube-macos")!)
                        .font(.system(size: 13, weight: .medium))
                }
            }
            SettingsGroup(title: "Удаление") {
                SettingsRow(symbol: "trash.fill", tint: .red, title: "Удалить zapret",
                            text: "Остановит обход и уберёт службы, правила файрвола, движки и прокси", last: true) {
                    Button("Удалить…") { confirmUninstall = true }
                        .buttonStyle(PillButtonStyle(tint: .red))
                        .disabled(model.busy)
                }
            }
        }
        .sheet(isPresented: $telegramSheet) { TelegramSheet() }
        .confirmationDialog("Удалить zapret?", isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("Удалить zapret", role: .destructive) { Task { await model.uninstallZapret(everything: false) } }
            Button("Удалить zapret и приложение", role: .destructive) { Task { await model.uninstallZapret(everything: true) } }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Обход перестанет работать. «И приложение» — ещё и это приложение с папкой ~/zapret-macos в Корзину. Понадобится пароль.")
        }
    }

    private func toggle(_ value: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle("", isOn: Binding(get: { value }, set: set)).labelsHidden().toggleStyle(.switch).tint(Theme.glow)
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).sectionTitle().padding(.leading, 4)
            VStack(spacing: 0) { content }
                .glassCard()
        }
    }
}

struct SettingsRow<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String
    var last = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                IconTile(symbol: symbol, gradient: LinearGradient(colors: [tint.opacity(0.8), tint], startPoint: .top, endPoint: .bottom), size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                accessory
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            if !last { Divider().padding(.leading, 58) }
        }
    }
}
