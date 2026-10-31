import SwiftUI

/// The grove at a glance: every plant with its health band, one push from its
/// quick-log. This page exists for the ad-hoc moment — watering can in hand,
/// no task scheduled — that the phone's own history most under-reported.
struct WatchGroveView: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        NavigationStack {
            Group {
                if store.plants.isEmpty {
                    empty
                } else {
                    List(store.plants) { plant in
                        NavigationLink(value: plant.id) {
                            WatchPlantRow(plant: plant)
                        }
                    }
                }
            }
            .navigationTitle("Grove")
            .navigationDestination(for: UUID.self) { plantID in
                WatchPlantDetailView(plantID: plantID)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.viewfinder")
                .font(.title2)
                .foregroundStyle(WatchTheme.accent)
            Text("No plants yet")
                .font(.headline)
            Text("Scan your first plant with Grove on your iPhone.")
                .font(.footnote)
                .foregroundStyle(WatchTheme.mutedInk)
                .multilineTextAlignment(.center)
        }
        .scenePadding()
    }
}

private struct WatchPlantRow: View {
    let plant: WatchPlantSummary

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(plant.band.color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(plant.nickname)
                    .font(.headline)
                    .lineLimit(1)
                Text(plant.species)
                    .font(.footnote)
                    .foregroundStyle(WatchTheme.mutedInk)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(plant.nickname), \(plant.species)")
        .accessibilityValue("\(plant.band.title), health score \(plant.healthScore)")
    }
}

/// One plant: its band, score and trend as the phone last assessed them, its
/// next check-in, and the five one-tap logs. Looked up live by id so a
/// snapshot landing mid-scroll updates this screen rather than stranding it.
struct WatchPlantDetailView: View {
    @Environment(WatchStore.self) private var store
    let plantID: UUID

    var body: some View {
        if let plant = store.plant(id: plantID) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                List {
                    Section {
                        header(for: plant)
                            .listRowBackground(Color.clear)
                    }
                    Section("Log care") {
                        ForEach(WatchCareKind.loggable, id: \.self) { kind in
                            logRow(kind, plant: plant, now: context.date)
                        }
                    }
                }
            }
            .navigationTitle(plant.nickname)
        } else {
            // The plant left the snapshot (deleted on the phone) while this
            // screen was open.
            Text("This plant is no longer in your grove.")
                .font(.footnote)
                .foregroundStyle(WatchTheme.mutedInk)
                .multilineTextAlignment(.center)
                .scenePadding()
        }
    }

    private func header(for plant: WatchPlantSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(plant.species)
                .font(.footnote)
                .foregroundStyle(WatchTheme.mutedInk)
            HStack(spacing: 6) {
                Image(systemName: plant.band.icon)
                    .foregroundStyle(plant.band.color)
                Text(plant.band.title)
                    .font(.headline)
                    .foregroundStyle(plant.band.color)
                Spacer()
                Text("\(plant.healthScore)")
                    .font(.title3.weight(.semibold))
                Image(systemName: plant.trend.icon)
                    .font(.footnote)
                    .foregroundStyle(plant.trend.color)
                    .accessibilityLabel(plant.trend.title)
            }
            checkInLine(for: plant)
        }
    }

    private func checkInLine(for plant: WatchPlantSummary) -> some View {
        let isDue = plant.nextCheckIn <= .now
        return HStack(spacing: 4) {
            Image(systemName: "camera.viewfinder")
            Text(
                isDue
                    ? "Check-in due. Open Grove on your iPhone"
                    : "Check-in \(plant.nextCheckIn.formatted(.relative(presentation: .named)))"
            )
        }
        .font(.footnote)
        .foregroundStyle(isDue ? WatchTheme.warning : WatchTheme.mutedInk)
    }

    private func logRow(_ kind: WatchCareKind, plant: WatchPlantSummary, now: Date) -> some View {
        let state = store.actionState(plantID: plant.id, kind: kind, now: now)
        let isPending = state == .pending
        let isAccepted: Bool
        let rejection: String?
        switch state {
        case .accepted:
            isAccepted = true
            rejection = nil
        case .rejected(let message):
            isAccepted = false
            rejection = message
        case .pending, nil:
            isAccepted = false
            rejection = nil
        }

        return Button {
            guard !isPending, !isAccepted else { return }
            store.logCare(plantID: plant.id, kind: kind)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: isAccepted ? "checkmark" : isPending ? "clock" : kind.icon)
                        .foregroundStyle(isAccepted ? WatchTheme.accent : kind.tint)
                        .frame(width: 24)
                    Text(isAccepted ? "Logged" : isPending ? "Sending…" : kind.logTitle)
                        .font(.body)
                        .foregroundStyle(isAccepted || isPending ? WatchTheme.mutedInk : WatchTheme.ink)
                }
                if let rejection {
                    Text(rejection)
                        .font(.caption2)
                        .foregroundStyle(WatchTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The wrist can answer before the tap when the phone already
                // knows. The button stays enabled: the phone remains the
                // authority and will reject with the same sentence.
                if kind == .water,
                   rejection == nil,
                   !isAccepted,
                   let lastWateredAt = plant.lastWateredAt,
                   RecentWateringGuard.isRecent(lastWateredAt, now: now) {
                    Text(RecentWateringGuard.message(lastWateredAt: lastWateredAt, now: now))
                        .font(.caption2)
                        .foregroundStyle(WatchTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .disabled(isPending || isAccepted)
    }
}
