import SwiftUI
import UIKit

// MARK: - Plant page cards

/// Shown when a plant is resting, archived or remembered. Care is paused, so
/// the one thing to offer is bringing it back.
struct PlantLifecycleBanner: View {
    let plant: Plant

    @Environment(GroveStore.self) private var store
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ConnectivityMonitor.self) private var connectivity

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                GroveSymbolTile(symbol: plant.effectiveLifecycleState.icon, tint: GroveTheme.subtleInk)
                VStack(alignment: .leading, spacing: 4) {
                    Text(plant.effectiveLifecycleState.title)
                        .font(.headline)
                        .foregroundStyle(GroveTheme.ink)
                    Text(plant.effectiveLifecycleState.detail)
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(action: resume) {
                GroveOutlineLabel(title: "Resume care", systemImage: "leaf.fill", size: .compact)
            }
            .buttonStyle(GrovePressStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .groveCard()
    }

    private func resume() {
        guard let updated = store.updatePlantRecord(
            id: plant.id,
            lifecycleState: .active,
            acquiredAt: plant.acquiredAt,
            notes: plant.profileNotes,
            environmentReadings: plant.environmentReadings ?? [],
            carePlan: plant.carePlan
        ) else {
            Haptics.error()
            return
        }
        Haptics.commit()
        let request = UpdatePlantRequest(plant: updated, clientRequestID: UUID())
        Task {
            await syncEngine.enqueue(.updatePlant(request), isConnected: connectivity.isConnected)
        }
    }
}

struct PlantCarersCard: View {
    let plantID: UUID
    let assignments: [SittingAssignment]
    let invites: [SittingInvite]

    var body: some View {
        PlantSection(title: "Carers", icon: "person.2.fill") {
            if assignments.isEmpty && invites.isEmpty {
                Text("Nobody else currently has a handover for this plant.")
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
            } else {
                ForEach(assignments) { assignment in
                    carerRow(
                        name: assignment.sitterName,
                        detail: "\(assignment.currentStatus().title) · \(dateRange(assignment.startDate, assignment.endDate))",
                        note: assignment.ownerNotes
                    )
                }
                ForEach(invites) { invite in
                    carerRow(
                        name: invite.sitterLabel,
                        detail: "Sitting link · \(dateRange(invite.startDate, invite.endDate))",
                        note: invite.ownerNotes
                    )
                }
            }

            NavigationLink(value: AppRoute.sittingLinkForPlant(plantID)) {
                GroveOutlineLabel(title: "Arrange plant care", systemImage: "link.badge.plus")
            }
            .buttonStyle(GrovePressStyle())
        }
    }

    private func carerRow(name: String, detail: String, note: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            GroveSymbolTile(symbol: "person.crop.circle.fill", tint: GroveTheme.purple, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.subheadline.weight(.bold))
                Text(detail).font(.caption).foregroundStyle(GroveTheme.mutedInk)
                if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(GroveTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func dateRange(_ start: Date, _ end: Date) -> String {
        "\(start.formatted(date: .abbreviated, time: .omitted))–\(end.formatted(date: .abbreviated, time: .omitted))"
    }
}

// MARK: - Full history and diagnosis

struct PlantHistoryView: View {
    @Environment(GroveStore.self) private var store
    let plantID: UUID

    private enum EntryKind {
        case observation(PlantObservation)
        case diagnosis(PlantDiagnosis)
        case care(CareTask)
    }

    private struct Entry: Identifiable {
        let id: String
        let date: Date
        let kind: EntryKind
    }

    private var entries: [Entry] {
        let observations = store.observations(for: plantID).map {
            Entry(id: "observation-\($0.id)", date: $0.createdAt, kind: .observation($0))
        }
        let diagnoses = store.diagnoses(for: plantID).map {
            Entry(id: "diagnosis-\($0.id)", date: $0.createdAt, kind: .diagnosis($0))
        }
        let care = store.tasks.filter {
            $0.plantID == plantID && $0.isCompleted && $0.kind != .checkIn
        }.map {
            Entry(id: "care-\($0.id)", date: $0.performedAt, kind: .care($0))
        }
        return (observations + diagnoses + care).sorted { $0.date > $1.date }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                GrovePageHeader(
                    title: "Complete history",
                    subtitle: "Every check-in note, diagnosis and care event in one chronology."
                )
                if let plant = store.plant(id: plantID) {
                    PlantProgressCard(
                        plant: plant,
                        progress: PlantPageProgress.make(
                            plant: plant, observations: store.observations(for: plantID),
                            scans: store.scanHistory, tasks: store.tasks
                        ),
                        expanded: true
                    )
                }
                if entries.isEmpty {
                    GroveEmptyState(
                        scene: .emptyShelf,
                        title: "No history yet",
                        message: "Check-ins, diagnoses and care events will appear here."
                    )
                } else {
                    ForEach(entries) { entry in historyEntry(entry) }
                }
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.top, GroveTheme.pageTopPadding)
            .padding(.bottom, GroveTheme.pageBottomPadding)
        }
        .groveBackground()
        .grovePageTitle("Plant history")
    }

    @ViewBuilder
    private func historyEntry(_ entry: Entry) -> some View {
        switch entry.kind {
        case .observation(let observation):
            VStack(alignment: .leading, spacing: 8) {
                entryHeader("Check-in", icon: "camera.viewfinder", date: entry.date, tint: observation.band.color)
                Text(
                    ([
                        "Health \(observation.previousScore) → \(observation.score)",
                        observation.appearance.title,
                        observation.answeredSoilMoisture.map { "soil \($0.title.lowercased())" }
                    ] as [String?])
                    .compactMap { $0 }
                    .joined(separator: " · ")
                )
                    .font(.subheadline.weight(.semibold))
                if !observation.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(observation.note)
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Recorded by \(observation.actorName)")
                    .font(.caption)
                    .foregroundStyle(GroveTheme.subtleInk)
            }
            .groveCard()
        case .diagnosis(let diagnosis):
            NavigationLink(value: AppRoute.plantDiagnosis(diagnosis.id)) {
                VStack(alignment: .leading, spacing: 8) {
                    entryHeader("Diagnosis", icon: "stethoscope", date: entry.date, tint: diagnosis.healthBand.color)
                    Text(diagnosis.possibleConditions.first?.name ?? diagnosis.healthBand.title)
                        .font(.headline)
                        .foregroundStyle(GroveTheme.ink)
                    Text(diagnosis.summary)
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Label("Open full diagnosis", systemImage: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(GroveTheme.accentStrong)
                }
                .groveCard()
            }
            .buttonStyle(GroveTilePressStyle())
        case .care(let task):
            VStack(alignment: .leading, spacing: 8) {
                entryHeader(task.kind.loggedTitle.capitalized, icon: task.kind.icon, date: entry.date, tint: GroveTheme.accentStrong)
                Text(task.detail)
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                if task.isSittingTask {
                    Text("Logged by \(task.ownerName ?? "a plant sitter")")
                        .font(.caption)
                        .foregroundStyle(GroveTheme.subtleInk)
                }
            }
            .groveCard()
        }
    }

    private func entryHeader(_ title: String, icon: String, date: Date, tint: Color) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
            Spacer()
            Text(date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(GroveTheme.subtleInk)
        }
    }
}

struct PlantDiagnosisDetailView: View {
    @Environment(GroveStore.self) private var store
    let diagnosisID: UUID

    private var diagnosis: PlantDiagnosis? { store.diagnoses.first { $0.id == diagnosisID } }

    var body: some View {
        Group {
            if let diagnosis {
                ScrollView {
                    VStack(alignment: .leading, spacing: GroveTheme.sectionSpacing) {
                        GrovePageHeader(
                            title: diagnosis.possibleConditions.first?.name ?? "Plant diagnosis",
                            subtitle: diagnosis.createdAt.formatted(date: .long, time: .shortened)
                        ) {
                            HealthScoreRing(score: diagnosis.confidence, band: diagnosis.healthBand)
                        }

                        if let photoURL = diagnosis.photoURL {
                            DiagnosisEvidencePhoto(url: photoURL)
                        }

                        PlantSection(title: "Assessment", icon: "waveform.path.ecg") {
                            Text(diagnosis.summary)
                                .font(.body)
                                .foregroundStyle(GroveTheme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            metadata(diagnosis)
                        }

                        if !diagnosis.possibleConditions.isEmpty {
                            PlantSection(title: "Possible conditions", icon: "list.bullet.clipboard.fill") {
                                ForEach(diagnosis.possibleConditions) { candidate in
                                    VStack(alignment: .leading, spacing: 7) {
                                        HStack {
                                            Text(candidate.name).font(.headline)
                                            Spacer()
                                            Text("\(candidate.confidence)%")
                                                .font(.caption.bold()).monospacedDigit()
                                        }
                                        Text(candidate.explanation)
                                            .font(.subheadline)
                                            .foregroundStyle(GroveTheme.mutedInk)
                                            .fixedSize(horizontal: false, vertical: true)
                                        ForEach(candidate.evidence, id: \.self) { evidence in
                                            Label(evidence, systemImage: "checkmark.circle.fill")
                                                .font(.caption)
                                                .foregroundStyle(GroveTheme.ink)
                                        }
                                        if let alternative = candidate.alternativeExplanation, !alternative.isEmpty {
                                            Text("Alternative: \(alternative)")
                                                .font(.caption)
                                                .foregroundStyle(GroveTheme.subtleInk)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }

                        listSection("What to do", icon: "checkmark.circle.fill", items: diagnosis.actionsToTake, tint: GroveTheme.accentStrong)
                        listSection("What to avoid", icon: "xmark.octagon.fill", items: diagnosis.actionsToAvoid, tint: GroveTheme.warning)
                        listSection("Limitations", icon: "exclamationmark.bubble.fill", items: diagnosis.limitations ?? [], tint: GroveTheme.subtleInk)

                        if let questions = diagnosis.clarifyingQuestions, !questions.isEmpty {
                            PlantSection(title: "Questions that would sharpen this diagnosis", icon: "questionmark.bubble.fill") {
                                ForEach(questions) { question in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(question.prompt).font(.subheadline.weight(.bold))
                                        if let reason = question.reason {
                                            Text(reason).font(.caption).foregroundStyle(GroveTheme.mutedInk)
                                        }
                                        Text(question.options.map(\.title).joined(separator: " · "))
                                            .font(.caption)
                                            .foregroundStyle(GroveTheme.subtleInk)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, GroveTheme.pagePadding)
                    .padding(.top, GroveTheme.pageTopPadding)
                    .padding(.bottom, GroveTheme.pageBottomPadding)
                }
                .groveBackground()
            } else {
                GroveEmptyState(scene: .vanished, title: "Diagnosis not found", message: "This diagnosis is no longer in the plant record.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .groveBackground()
            }
        }
        .grovePageTitle("Diagnosis")
    }

    private func metadata(_ diagnosis: PlantDiagnosis) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(diagnosis.confidence)% assessment confidence", systemImage: "gauge.with.dots.needle.50percent")
            if let provider = diagnosis.providerName { Label(provider, systemImage: "brain.head.profile") }
            if let version = diagnosis.analysisVersion { Label("Analysis \(version)", systemImage: "number") }
            if let actionability = diagnosis.actionability {
                Label(actionability.rawValue.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized, systemImage: "checkmark.shield.fill")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(GroveTheme.subtleInk)
    }

    @ViewBuilder
    private func listSection(_ title: String, icon: String, items: [String], tint: Color) -> some View {
        if !items.isEmpty {
            PlantSection(title: title, icon: icon) {
                ForEach(items, id: \.self) { item in
                    Label {
                        Text(item).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: icon).foregroundStyle(tint)
                    }
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.ink)
                }
            }
        }
    }
}

/// The photograph the diagnosis was based on. It is kept inline with the
/// assessment so the evidence remains reachable after the one-off scan flow.
private struct DiagnosisEvidencePhoto: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    GroveTheme.secondarySurface
                    ProgressView().tint(GroveTheme.accentStrong)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 230)
        .clipShape(RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
                .stroke(GroveTheme.separator, lineWidth: 1)
        }
        .accessibilityLabel("Photo used for this diagnosis")
        .task(id: url) {
            guard let resolved = GroveMediaPath.resolved(url) else {
                image = nil
                return
            }
            image = await GroveImageLoader.downsampledImage(at: resolved, maxDimension: 1200)
        }
    }
}
