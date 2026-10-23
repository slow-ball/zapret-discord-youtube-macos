import SwiftUI

@main
struct ZapretApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    init() {
        if Snapshot.folder != nil {
            let m = model
            DispatchQueue.main.async { Snapshot.run(m) }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environment(model)
        } label: {
            MenuBarLabel(running: model.status.running)
        }
        .menuBarExtraStyle(.window)

        Window("zapret", id: "main") {
            MainView()
                .environment(model)
                .frame(minWidth: 780, minHeight: 540)
        }
        .defaultSize(width: 1000, height: 720)
        .windowStyle(.hiddenTitleBar)
    }
}

/// the menu bar icon. It always exists, so it hands the model a way to open the main window
/// (for zapret://open from the widget)
private struct MenuBarLabel: View {
    let running: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarIcon.image(running: running))
            .onAppear {
                let open = openWindow
                AppModel.shared.openMainWindow = {
                    open(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}
