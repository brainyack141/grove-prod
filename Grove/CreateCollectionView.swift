import SwiftUI

/// Create or edit a plant collection. Mirrors the reference "Create a collection"
/// sheet — name + icon picker — and adds a Grove-native colourway and inline
/// plant selection so a freshly created collection is never empty.
struct CreateCollectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(GroveStore.self) private var store

    private let editingCollectionID: UUID?

    @State private var name = ""
    @State private var symbol = PlantCollection.iconChoices.first ?? "folder.fill"
    @State private var palette: PlantPalette = .fern
    @State private var selectedPlantIDs = Set<UUID>()

    /// `preselecting` seeds membership when the sheet is opened from a plant, so
    /// "New collection…" on a plant lands you in a collection that already
    /// contains it rather than an empty one you then have to go and fill.
    init(editing collection: PlantCollection? = nil, preselecting plantIDs: Set<UUID> = []) {
        editingCollectionID = collection?.id
        if let collection {
            _name = State(initialValue: collection.name)
            _symbol = State(initialValue: collection.symbol)
            _palette = State(initialValue: collection.palette)
            _selectedPlantIDs = State(initialValue: Set(collection.plantIDs))
        } else {
            _selectedPlantIDs = State(initialValue: plantIDs)
        }
    }

    private var isEditing: Bool { editingCollectionID != nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty }

    private let iconColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GroveTheme.sectionSpacing) {
                    hero
                    nameSection
                    iconSection
                    colourSection
                    if !store.plants.isEmpty { plantSection }
                }
                .padding(.horizontal, GroveTheme.pagePadding)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .groveBackground()
            .groveEditorialPage(isEditing ? "Edit collection" : "Create a collection")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { saveBar }
        }
    }

    // MARK: - Sections

    /// The hero is the collection itself, drawn exactly as it will appear on My
    /// Grove and updating as you type and pick. A stock illustration here would
    /// explain what a collection is; this shows you the one you are making, and
    /// gives every control below a visible consequence.
    private var hero: some View {
        CollectionPreviewCard(
            name: trimmedName,
            symbol: symbol,
            palette: palette,
            members: selectedPlants
        )
        .animation(GroveMotion.pop, value: palette)
        .animation(GroveMotion.snap, value: symbol)
    }

    /// Ordered by the grove, not by tap order, so the peek doesn't reshuffle
    /// itself every time you change your mind.
    private var selectedPlants: [Plant] {
        store.plants.filter { selectedPlantIDs.contains($0.id) }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Name your collection").font(.headline)
            TextField("Bathroom, rescues, Mum's cuttings…", text: $name)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous)
                        .stroke(GroveTheme.separator, lineWidth: 1)
                }
                .submitLabel(.done)
                .accessibilityIdentifier("collectionNameField")
        }
    }

    private var iconSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick an icon").font(.headline)
            LazyVGrid(columns: iconColumns, spacing: 12) {
                ForEach(PlantCollection.iconChoices, id: \.self) { choice in
                    let isSelected = choice == symbol
                    Button {
                        guard choice != symbol else { return }
                        Haptics.selection()
                        withAnimation(GroveMotion.snap) { symbol = choice }
                    } label: {
                        GroveCollectionIcon(symbol: choice, size: 38)
                            .scaleEffect(isSelected ? 1.06 : 1)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(
                                isSelected ? GroveTheme.softAccent : GroveTheme.surface,
                                in: RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous)
                                    .stroke(isSelected ? GroveTheme.accent : GroveTheme.separator, lineWidth: isSelected ? 2 : 1)
                            }
                    }
                    .buttonStyle(GroveTilePressStyle())
                    .accessibilityLabel(PlantCollection.iconLabel(for: choice))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    private var colourSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Colour").font(.headline)
            // Ten swatches no longer fit a row, and a horizontal scroller would
            // hide half of them behind a gesture. Two rows on the icon grid's
            // own five columns keeps every colour visible and makes the two
            // pickers rhyme instead of each inventing its own rhythm.
            LazyVGrid(columns: iconColumns, spacing: 14) {
                ForEach(PlantCollection.paletteChoices, id: \.self) { choice in
                    let isSelected = choice == palette
                    Button {
                        guard choice != palette else { return }
                        Haptics.selection()
                        withAnimation(GroveMotion.pop) { palette = choice }
                    } label: {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: choice.colors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 40, height: 40)
                            // The chosen swatch grows into its ring rather than
                            // having one drawn around it.
                            .scaleEffect(isSelected ? 1.12 : 1)
                            .overlay {
                                Circle().stroke(GroveTheme.accent, lineWidth: isSelected ? 3 : 0)
                                    .padding(-3)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                    }
                    .buttonStyle(GroveTilePressStyle())
                    .accessibilityLabel(choice.label)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    private var plantSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Add plants").font(.headline)
                Spacer()
                Text(selectedPlantIDs.isEmpty ? "Optional" : "\(selectedPlantIDs.count) selected")
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
            }
            VStack(spacing: 0) {
                ForEach(Array(store.plants.enumerated()), id: \.element.id) { index, plant in
                    Button {
                        let adding = !selectedPlantIDs.contains(plant.id)
                        Haptics.toggle(on: adding)
                        withAnimation(GroveMotion.pop) {
                            if adding { selectedPlantIDs.insert(plant.id) }
                            else { selectedPlantIDs.remove(plant.id) }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            PlantThumbnail(plant: plant, height: 40, maxDimension: 160)
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(plant.nickname).font(.subheadline.weight(.semibold))
                                Text(plant.location).font(.caption).foregroundStyle(GroveTheme.mutedInk)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: selectedPlantIDs.contains(plant.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selectedPlantIDs.contains(plant.id) ? GroveTheme.accent : GroveTheme.subtleInk)
                                // The tick swaps glyph *and* springs, so
                                // multi-select feels like collecting rather
                                // than like ticking a form.
                                .contentTransition(.symbolEffect(.replace))
                                .scaleEffect(selectedPlantIDs.contains(plant.id) ? 1.1 : 1)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(GroveCardPressStyle(scale: 0.985, haptics: false))
                    .foregroundStyle(GroveTheme.ink)
                    if index < store.plants.count - 1 {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
            .groveEdgeLight()
            .groveShadow(.resting)
        }
    }

    private var saveBar: some View {
        Button {
            save()
        } label: {
            GroveCTALabel(
                title: isEditing ? "Save changes" : "Create collection",
                systemImage: "checkmark"
            )
        }
        .buttonStyle(GrovePressStyle())
        .disabled(!canSave)
        // Dims the button, not the bar: applied after `groveActionBar` the
        // opacity would fade the gradient the bar uses to dissolve into the
        // canvas, and the page would appear to lift off its own background.
        .opacity(canSave ? 1 : 0.4)
        .animation(GroveMotion.snap, value: canSave)
        .accessibilityIdentifier("createCollectionButton")
        .groveActionBar()
    }

    private func save() {
        guard canSave else { return }
        if let editingCollectionID {
            store.updateCollection(id: editingCollectionID, name: trimmedName, symbol: symbol, palette: palette)
            store.setPlants(selectedPlantIDs, inCollection: editingCollectionID)
        } else {
            store.createCollection(name: trimmedName, symbol: symbol, palette: palette, plantIDs: selectedPlantIDs)
        }
        // Editing is a save; creating a corner of the grove is a small making.
        if editingCollectionID == nil { Haptics.celebrate() } else { Haptics.commit() }
        dismiss()
    }
}

/// The collection cover as it will sit on My Grove, at hero scale, driven by
/// whatever the sheet currently holds. Deliberately the same cover anatomy the
/// collection banner and collection page draw — gradient, icon, member peek,
/// name and count — so what you build here is recognizably what you get there.
private struct CollectionPreviewCard: View {
    let name: String
    let symbol: String
    let palette: PlantPalette
    let members: [Plant]

    private var isUnnamed: Bool { name.isEmpty }
    private var displayName: String { isUnnamed ? "Untitled collection" : name }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: palette.colors, startPoint: .topLeading, endPoint: .bottomTrailing)

                GroveCollectionIcon(symbol: symbol, size: 120)
                    .opacity(0.16)
                    .rotationEffect(.degrees(-10))
                    .offset(x: 210, y: 30)

                VStack(alignment: .leading, spacing: 0) {
                    GroveCollectionIcon(symbol: symbol, size: 30)
                        .padding(6)
                        .frame(width: 42, height: 42)
                        .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
                        .contentTransition(.opacity)
                    Spacer(minLength: 10)
                    peek
                }
                .padding(14)
            }
            .frame(height: 132)

            VStack(alignment: .leading, spacing: 3) {
                GroveDisplayHeading(
                    text: displayName,
                    style: .card,
                    color: isUnnamed ? GroveTheme.subtleInk : GroveTheme.ink
                )
                .lineLimit(1)
                Text("\(members.count) \(members.count == 1 ? "plant" : "plants")")
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .frame(maxWidth: .infinity)
        .background(GroveTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
        .groveEdgeLight()
        .groveShadow(.resting)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview: \(displayName), \(members.count) \(members.count == 1 ? "plant" : "plants")")
    }

    @ViewBuilder
    private var peek: some View {
        if members.isEmpty {
            Text("No plants yet")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.white.opacity(0.2), in: Capsule())
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
        } else {
            HStack(spacing: -10) {
                ForEach(members.prefix(5)) { plant in
                    PlantPortrait(plant: plant, height: 36)
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())
                        .overlay { Circle().stroke(.white.opacity(0.5), lineWidth: 1.5) }
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
                if members.count > 5 {
                    Text("+\(members.count - 5)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.24), in: Circle())
                        .overlay { Circle().stroke(.white.opacity(0.5), lineWidth: 1.5) }
                }
            }
        }
    }
}

#Preview {
    CreateCollectionView()
        .environment(GroveStore())
}
