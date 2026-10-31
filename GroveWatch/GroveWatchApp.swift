import SwiftUI

@main
struct GroveWatchApp: App {
    @State private var store = WatchStore()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(store)
                .tint(WatchTheme.accent)
                .task { store.activate() }
        }
    }
}

/// Two vertical pages — the day's work, then the grove — or the honest
/// first-run state when no snapshot has ever arrived from the phone.
struct WatchRootView: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        if store.hasSnapshot {
            TabView {
                WatchTodayView()
                WatchGroveView()
            }
            .tabViewStyle(.verticalPage)
        } else {
            WatchAwaitingSyncView()
        }
    }
}

/// Shown until the first snapshot lands. Says what to do, not what's missing.
private struct WatchAwaitingSyncView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "leaf.fill")
                .font(.title2)
                .foregroundStyle(WatchTheme.accent)
            Text("Open Grove on your iPhone")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Your plants sync over from there.")
                .font(.footnote)
                .foregroundStyle(WatchTheme.mutedInk)
                .multilineTextAlignment(.center)
        }
        .scenePadding()
    }
}
