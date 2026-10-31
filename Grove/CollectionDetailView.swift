import SwiftUI

/// A single collection: its members, plus the two actions that make a collection
/// worth having in Grove — manage which plants belong, and hand the whole set to
/// a plant sitter in one move.
struct CollectionDetailView: View {
    @Environment(GroveStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let collectionID: UUID

    @State private var isEditing = false
    @State private var isDelegating = false
    @State private var showDeleteConfirm = false

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    var body: some View {
        Group {
            if let collection = store.collection(id: collectionID) {
                content(for: collection)
            } else {
                // Collection was deleted out from under us — leave gracefully.
                GroveEmptyState(
                    scene: .vanished,
                    title: "This collection is gone",
                    message: "It is no longer part of your grove."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .groveBackground()
            }
        }
    }

    private func content(for collection: PlantCollection) -> some View {
        let members = store.plants(in: collectionID)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: GroveTheme.sectionSpacing) {
                header(for: collection, memberCount: members.count)

                Button {
                    isDelegating = true
                } label: {
                    GroveCTALabel(title: "Assign to a sitter", systemImage: "person.2.fill")
                }
                .buttonStyle(GrovePressStyle())
                .disabled(members.isEmpty)
                .opacity(members.isEmpty ? 0.5 : 1)

                if members.isEmpty {
                    GroveEmptyState(
                        scene: .emptyShelf,
                        title: "Nothing on this shelf",
                        message: "Add plants and you can filter your grove, or hand the whole group to a sitter at once."
                    )
                    .frame(minHeight: 220)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(members) { plant in
                            NavigationLink(value: AppRoute.plant(plant.id)) {
                                PlantCard(plant: plant)
                            }
                            .buttonStyle(GroveCardPressStyle())
                            .plantQuickActions(for: plant, in: collectionID)
                            .groveHeroSource(.plant(plant.id))
                        }
                    }
                }
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.top, GroveTheme.pageTopPadding)
            .padding(.bottom, GroveTheme.pageBottomPadding)
        }
        .groveBackground()
        .groveEditorialPage(collection.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        isEditing = true
                    } label: {
                        Label("Manage plants & details", systemImage: "slider.horizontal.3")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete collection", systemImage: "trash")
                    }
                } label: {
                    GroveHeaderIcon(symbol: "ellipsis")
                }
                .accessibilityLabel("Collection options")
            }
        }
        .sheet(isPresented: $isEditing) {
            CreateCollectionView(editing: collection)
        }
        .sheet(isPresented: $isDelegating) {
            NavigationStack {
                SittingLinkView(preselectedPlantIDs: Set(collection.plantIDs), recipient: .friend)
            }
        }
        .confirmationDialog("Delete “\(collection.name)”?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete collection", role: .destructive) {
                store.deleteCollection(id: collectionID)
                dismiss()
            }
        } message: {
            Text("The plants stay exactly where they are. Only the grouping goes.")
        }
    }

    private func header(for collection: PlantCollection, memberCount: Int) -> some View {
        HStack(spacing: 16) {
            GroveCollectionIcon(symbol: collection.symbol, size: 50)
                .padding(9)
                .frame(width: 68, height: 68)
                .background(
                    LinearGradient(colors: collection.palette.colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 6) {
                GroveDisplayHeading(text: collection.name, style: .section)
                Text("\(memberCount) \(memberCount == 1 ? "plant" : "plants")")
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
            }
            Spacer(minLength: 0)
        }
        .groveCard()
    }
}

#Preview {
    let store = GroveStore()
    return AppDestinationsPreviewHost {
        CollectionDetailView(collectionID: store.collections.first?.id ?? UUID())
    }
    .environment(store)
}
