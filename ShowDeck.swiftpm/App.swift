import ShowKit
import SwiftUI

@main
struct ShowDeckApp: App {
    @State private var show = Show(fileURL: Show.defaultFileURL, transport: NetworkTransports.make)
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(show)
                .onAppear { show.connectAutomatically() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                show.resume()
            case .inactive:
                show.releaseTouches()
            case .background:
                // iOS drops sockets in the background; reconnect and re-read on return.
                show.suspend()
            default:
                break
            }
        }
    }
}

struct RootView: View {
    @Environment(Show.self) private var show

    var body: some View {
        TabView {
            DeskView()
                .tabItem { Label("Desk", systemImage: "slider.vertical.3") }
            CuesView()
                .tabItem { Label("Cues", systemImage: "square.grid.2x2") }
            NavigationStack {
                DevicesView()
            }
            .tabItem { Label("Devices", systemImage: "cable.connector") }
        }
        // Keep the screen on while anything is connected: it's a show.
        .onChange(of: show.devices.contains { $0.isActive }, initial: true) { _, anyActive in
            UIApplication.shared.isIdleTimerDisabled = anyActive
        }
    }
}
