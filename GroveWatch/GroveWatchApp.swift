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
                .modifier(WatchQADynamicTypeOverride())
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

/// Screenshot harness hook: `-GroveQADynamicType <simctl content size>` forces a
/// Dynamic Type size, because `simctl ui content_size` does not reach watchOS.
/// Debug builds only; release builds always follow the wearer's setting.
private struct WatchQADynamicTypeOverride: ViewModifier {
    func body(content: Content) -> some View {
        if let size = Self.override {
            content.dynamicTypeSize(size)
        } else {
            content
        }
    }

    private static var override: DynamicTypeSize? {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "GroveQADynamicType") {
        case "extra-small": return .xSmall
        case "small": return .small
        case "medium": return .medium
        case "large": return .large
        case "extra-large": return .xLarge
        case "extra-extra-large": return .xxLarge
        case "extra-extra-extra-large": return .xxxLarge
        case "accessibility-medium": return .accessibility1
        case "accessibility-large": return .accessibility2
        case "accessibility-extra-large": return .accessibility3
        case "accessibility-extra-extra-large": return .accessibility4
        case "accessibility-extra-extra-extra-large": return .accessibility5
        default: return nil
        }
        #else
        return nil
        #endif
    }
}
