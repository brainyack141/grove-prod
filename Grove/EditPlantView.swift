import SwiftUI

struct EditPlantView: View {
    @Environment(GroveStore.self) private var store
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(\.dismiss) private var dismiss
    let plantID: UUID

    @State private var nickname = ""
    @State private var location = "Living room"
    @State private var lightPlacement: PlantLightPlacement?
    @State private var checkInFrequencyDays: Int?
    @State private var commonName = ""
    @State private var scientificName = ""
    @State private var isNamingCustomRoom = false
    @State private var customRoom = ""
    @FocusState private var customRoomFocused: Bool

    private let locations = ["Living room", "Bedroom", "Kitchen", "Office", "Balcony", "Garden"]

    /// The Add flow accepts free-text locations, so the plant's current
    /// location may not be one of the standard rooms. Keep it selectable —
    /// otherwise the picker renders with no selected value and the custom
    /// location is silently lost on the first tap.
    private var locationOptions: [String] {
        var options = locations
        let stored = store.plant(id: plantID)?.location
        for custom in [stored, location].compactMap({ $0 }) where !options.contains(custom) && Self.isNamed(custom) {
            options.insert(custom, at: 0)
        }
        return options
    }

    /// "Unassigned" is the absence of a room, not a room to pick.
    private static func isNamed(_ room: String) -> Bool {
        let trimmed = room.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.caseInsensitiveCompare("Unassigned") != .orderedSame
    }

    /// The room question from first run: the room drawn with the plant in it,
    /// and every room as a chip. A spot with no picture of its own keeps the
    /// chip alone.
    private var roomSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                if let room = OnboardingRoom(matching: location) {
                    RoomScene(room: room)
                        .frame(maxWidth: .infinity)
                        .id(room)
                        .transition(.opacity)
                }
                GroveFlowLayout(spacing: 8) {
                    ForEach(locationOptions, id: \.self) { option in
                        GroveRoomChip(title: option, isSelected: !isNamingCustomRoom && location == option) {
                            location = option
                            isNamingCustomRoom = false
                        }
                    }
                    GroveRoomChip(title: "New spot", symbolOverride: "plus", isSelected: isNamingCustomRoom) {
                        isNamingCustomRoom = true
                        customRoomFocused = true
                    }
                }
                if isNamingCustomRoom {
                    TextField("Name the spot: Sunroom, Porch…", text: $customRoom)
                        .font(.body.weight(.semibold))
                        .focused($customRoomFocused)
                        .submitLabel(.done)
                        .onSubmit(commitCustomRoom)
                        .onChange(of: customRoom) { _, _ in commitCustomRoom() }
                }
            }
            .padding(.vertical, 6)
            .animation(GroveMotion.settle, value: location)
        } header: {
            Text("Room")
        } footer: {
            Text("Its room places it on Today's map.")
        }
    }

    private func commitCustomRoom() {
        let trimmed = customRoom.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { location = trimmed }
    }

    var body: some View {
        Form {
            Section {
                TextField("Nickname", text: $nickname)
            } header: {
                Text("Plant")
            }
            roomSection
            Section {
                Picker("Light", selection: $lightPlacement) {
                    Text("Not sure yet").tag(PlantLightPlacement?.none)
                    ForEach(PlantLightPlacement.allCases, id: \.self) { placement in
                        Text(placement.title).tag(PlantLightPlacement?.some(placement))
                    }
                }
            } header: {
                Text("Light")
            } footer: {
                Text("Where it stands decides how much light reaches it. A sill gets about half of what falls outside; the far side of the room a twentieth.")
            }
            Section {
                Picker("Check-ins", selection: $checkInFrequencyDays) {
                    Text("Automatic").tag(Int?.none)
                    ForEach(Plant.checkInFrequencyOptions, id: \.self) { days in
                        Text(Plant.checkInFrequencyTitle(days: days)).tag(Int?.some(days))
                    }
                }
                .accessibilityIdentifier("editPlantCheckInFrequency")
            } header: {
                Text("Check-ins")
            } footer: {
                Text("Automatic lets Grove choose: sooner while the plant is struggling, less often once it’s thriving. A plant that needs attention may still be asked for sooner than your choice.")
            }
            Section("Plant identity") {
                TextField("Common name", text: $commonName)
                    .textContentType(.none)
                TextField("Scientific name (optional)", text: $scientificName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("A typed name updates this plant but stays unverified. Confirm it with a new identification scan before relying on species safety advice.")
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
            }
            Section {
                Button("Save changes", action: save)
                    .disabled(!canSave)
            }
        }
        .formStyle(.grouped)
        .groveGroupedContent()
        .grovePageTitle("Edit plant")
        .onAppear {
            guard let plant = store.plant(id: plantID) else { return }
            nickname = plant.nickname
            location = plant.location
            // The stored answer, not the inferred one: a guess read off the
            // room name must not present itself here as something the user
            // already told Grove.
            lightPlacement = plant.lightPlacement
            checkInFrequencyDays = plant.checkInFrequencyDays
            // Placeholders an unidentified plant was created with are not
            // names. Loading them as values made "Species unconfirmed" save
            // as a typed Latin name the moment the owner named the plant.
            commonName = Self.isPlaceholder(plant.species) ? "" : plant.species
            scientificName = Self.isPlaceholder(plant.scientificName) ? "" : plant.scientificName
        }
    }

    /// A plant Grove never named can keep an empty common name: moving an
    /// unknown plant to another room must not demand a name first.
    private var canSave: Bool {
        guard !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard commonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        return store.plant(id: plantID).map { Self.isPlaceholder($0.species) } ?? false
    }

    private static func isPlaceholder(_ name: String) -> Bool {
        PlantIdentityState.isPlaceholderName(name)
    }

    private func save() {
        guard let plant = store.plant(id: plantID) else { return }
        // Compare trimmed values: a stray trailing space must not count as an
        // identity correction, which resets confidence and replaces the
        // plant's guidance.
        let typedCommonName = commonName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedScientificName = scientificName.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedScientific = Self.isPlaceholder(plant.scientificName) ? "" : plant.scientificName
        let scientificChanged = trimmedScientificName.caseInsensitiveCompare(storedScientific) != .orderedSame
        let commonChanged = !typedCommonName.isEmpty && typedCommonName != plant.species
        let trimmedCommonName = typedCommonName.isEmpty
            ? (trimmedScientificName.isEmpty ? plant.species : trimmedScientificName)
            : typedCommonName

        // Only a new scientific name (or a first name for a plant Grove could
        // not identify) is an identity correction. Renaming a Swiss cheese
        // plant "Monstera" keeps its confirmed taxon, safety record and plan.
        if scientificChanged || (commonChanged && (PlantIdentityState.needsResolving(plant) || Self.isPlaceholder(plant.species))) {
            let scientific = trimmedScientificName.isEmpty ? "Species unconfirmed" : trimmedScientificName
            store.updatePlantIdentity(
                id: plantID,
                candidate: SpeciesCandidate(
                    id: scientific.lowercased().replacingOccurrences(of: " ", with: "-"),
                    commonName: trimmedCommonName,
                    scientificName: scientific,
                    confidence: 0,
                    distinguishingTraits: [],
                    regionalFit: "Manually entered"
                ),
                confirmation: .manualEntry
            )
        } else if commonChanged {
            store.renamePlantSpecies(id: plantID, commonName: trimmedCommonName)
        }
        store.updatePlant(
            id: plantID,
            nickname: nickname,
            location: location,
            lightPlacement: lightPlacement
        )
        let movedCheckIn = store.setCheckInFrequency(plantID: plantID, days: checkInFrequencyDays)
        if let updated = store.plant(id: plantID) {
            let request = UpdatePlantRequest(plant: updated, clientRequestID: UUID())
            Task {
                await syncEngine.enqueue(
                    .updatePlant(request),
                    isConnected: connectivity.isConnected
                )
            }
        }
        if let movedCheckIn {
            let request = CareTaskMutationRequest(
                taskID: movedCheckIn.id,
                outcome: .snoozed,
                occurredAt: .now,
                rescheduledFor: movedCheckIn.dueDate,
                reason: "Check-in frequency changed",
                clientRequestID: UUID()
            )
            Task {
                await syncEngine.enqueue(
                    .updateCareTask(request),
                    isConnected: connectivity.isConnected
                )
            }
        }
        Haptics.commit()
        dismiss()
    }
}
