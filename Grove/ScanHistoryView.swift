import SwiftUI
import UIKit

struct ScanHistoryView: View {
    @Environment(GroveStore.self) private var store
    @State private var searchText = ""
    @State private var grouping: ScanHistoryGrouping = .month
    @State private var selection: Set<UUID> = []

    private var filtered: [ScanHistoryRecord] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return store.scanHistory }
        return store.scanHistory.filter {
            $0.commonName.localizedCaseInsensitiveContains(searchText)
                || $0.scientificName.localizedCaseInsensitiveContains(searchText)
                || ($0.summary?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private func sections(for records: [ScanHistoryRecord]) -> [ScanHistorySection] {
        let groups = Dictionary(grouping: records) { grouping.key(for: $0) }
        return groups.map { ScanHistorySection(title: $0.key, records: $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { ($0.records.first?.createdAt ?? .distantPast) > ($1.records.first?.createdAt ?? .distantPast) }
    }

    var body: some View {
        let results = filtered
        Group {
            if store.scanHistory.isEmpty {
                GroveEmptyState(
                    scene: .viewfinder,
                    title: "No scans yet",
                    message: "Every plant you identify or diagnose is saved here automatically."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                GroveEmptyState(
                    scene: .noMatches,
                    title: "No scans match",
                    message: "Nothing here answers to “\(searchText)”. Try a shorter word."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(sections(for: results)) { section in
                        Section(section.title) {
                            ForEach(section.records) { scan in
                                ScanHistoryRow(scan: scan)
                                    .tag(scan.id)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) { store.deleteScanHistory(ids: [scan.id]) } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .groveGroupedContent()
        .searchable(text: $searchText, prompt: "Plant, species or finding")
        .grovePageTitle("Scan history")
        // Reached by push from the dark camera now, and this is a cream
        // grouped screen — same restoration JourneyQuests does when pushed
        // from the dark Journey map.
        .preferredColorScheme(.light)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Group scans", selection: $grouping) {
                        ForEach(ScanHistoryGrouping.allCases) { option in Text(option.title).tag(option) }
                    }
                } label: { Image(systemName: "rectangle.3.group") }
                EditButton()
            }
            if !selection.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) {
                        store.deleteScanHistory(ids: selection)
                        selection.removeAll()
                    } label: {
                        Label("Delete \(selection.count)", systemImage: "trash")
                    }
                }
            }
        }
    }
}

private enum ScanHistoryGrouping: String, CaseIterable, Identifiable {
    case month
    case purpose

    var id: Self { self }
    var title: String { self == .month ? "By month" : "By purpose" }

    func key(for scan: ScanHistoryRecord) -> String {
        switch self {
        case .month:
            return scan.createdAt.formatted(.dateTime.month(.wide).year())
        case .purpose:
            return scan.mode.title
        }
    }
}

private struct ScanHistorySection: Identifiable {
    let title: String
    let records: [ScanHistoryRecord]
    var id: String { title }
}

private struct ScanHistoryRow: View {
    let scan: ScanHistoryRecord

    var body: some View {
        HStack(spacing: 14) {
            ScanHistoryThumbnail(url: scan.photoURL)
                .frame(width: 68, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(scan.commonName).font(.headline)
                    if scan.isUnknown == true { Image(systemName: "questionmark.circle.fill").foregroundStyle(GroveTheme.warning) }
                }
                Text(scan.scientificName).font(.caption.italic()).foregroundStyle(GroveTheme.mutedInk)
                Text("\(scan.identificationConfidence)% match · \(scan.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
                Label(scan.healthBand.title, systemImage: scan.healthBand.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(scan.healthBand.color)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct ScanHistoryThumbnail: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack { GroveTheme.softAccent; Image(systemName: "leaf.fill").foregroundStyle(GroveTheme.accent) }
            }
        }
        .clipped()
        .task(id: url) {
            guard let url, let resolved = GroveMediaPath.resolved(url) else {
                image = nil
                return
            }
            image = await GroveThumbnailCache.thumbnail(at: resolved, maxDimension: 240)
        }
    }
}
