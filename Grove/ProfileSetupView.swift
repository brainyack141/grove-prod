import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ProfileSetupView: View {
    @Environment(GroveStore.self) private var store
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(GrovePremiumStore.self) private var premium
    @Environment(\.dismiss) private var dismiss

    let isOnboarding: Bool

    @State private var name = ""
    @State private var username = ""
    @State private var regionCode = Locale.current.region?.identifier ?? "GB"
    // .uk is a distinct case from .metric — comparing against .metric alone
    // would default UK devices to Imperial.
    @State private var usesMetricSystem = Locale.current.measurementSystem != .us
    @State private var selectedAvatarAssetName: String?
    @State private var existingAvatarPhotoURL: URL?
    @State private var customAvatarImage: UIImage?
    @State private var customAvatarData: Data?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isLoadingAvatar = false
    @State private var avatarErrorMessage: String?
    @State private var avatarPage = 0
    @State private var showingPremiumAvatarPaywall = false
    @State private var didLoad = false
    @FocusState private var focusedField: Field?

    var body: some View {
        Form {
            if isOnboarding {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        GroveSymbolTile(symbol: "person.crop.circle.badge.checkmark", size: 52)
                        GroveDisplayHeading(text: "Make this grove yours", style: .section)
                        Text("Your plants and photos stay separate from the demo grove and from anyone else using this device.")
                            .foregroundStyle(GroveTheme.mutedInk)
                    }
                    .padding(.vertical, 8)
                }
            }

            Section("Profile picture") {
                VStack(spacing: 18) {
                    profileAvatarPreview

                    VStack(spacing: 10) {
                        TabView(selection: $avatarPage) {
                            ForEach(AvatarView.imagePages.indices, id: \.self) { pageIndex in
                                avatarPageContent(pageIndex)
                                .tag(pageIndex)
                                .accessibilityElement(children: .contain)
                                .accessibilityLabel(avatarPageAccessibilityLabel(pageIndex))
                            }
                        }
                        .frame(height: avatarPickerHeight)
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .accessibilityHint("Swipe left or right to browse more profile pictures")

                        HStack(spacing: 8) {
                            ForEach(AvatarView.imagePages.indices, id: \.self) { pageIndex in
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        avatarPage = pageIndex
                                    }
                                } label: {
                                    Circle()
                                        .fill(
                                            pageIndex == avatarPage
                                                ? GroveTheme.accent
                                                : GroveTheme.separator
                                        )
                                        .frame(width: 8, height: 8)
                                        .frame(width: 24, height: 24)
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(
                                    "Profile picture page \(pageIndex + 1) of \(AvatarView.imagePages.count)"
                                )
                                .accessibilityAddTraits(pageIndex == avatarPage ? .isSelected : [])
                            }
                        }
                    }

                    photoPicker(
                        title: hasCustomAvatar ? "Choose a different photo" : "Choose a photo"
                    )

                    if isLoadingAvatar {
                        ProgressView("Preparing photo…")
                            .font(.footnote)
                            .foregroundStyle(GroveTheme.mutedInk)
                    } else if hasCustomAvatar {
                        Button("Use a Grove avatar instead") {
                            chooseAvatar(defaultAvatarAssetName)
                        }
                        .font(.footnote.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section("Profile") {
                TextField("Display name", text: $name)
                    .textContentType(.name)
                    .focused($focusedField, equals: .name)
                    .accessibilityIdentifier("profileDisplayName")
                HStack {
                    Text("@")
                        .foregroundStyle(GroveTheme.mutedInk)
                    TextField("username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .focused($focusedField, equals: .username)
                        .accessibilityIdentifier("profileUsername")
                }
            }

            Section("Region and measurements") {
                GroveRegionRow(code: $regionCode)
                Picker("Measurements", selection: $usesMetricSystem) {
                    Text("Metric").tag(true)
                    Text("Imperial").tag(false)
                }
            }

            Section("Privacy") {
                Label("Plant access is always explicit", systemImage: "lock.shield.fill")
                Text("Connections can see your name and username, never your grove. Plants are available only through a sitting link you create with its own dates and permissions.")
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.mutedInk)
            }
        }
        .formStyle(.grouped)
        .groveGroupedContent()
        .grovePageTitle(isOnboarding ? "Set up profile" : "Edit profile")
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { saveBar }
        .alert(
            "Profile photo",
            isPresented: Binding(
                get: { avatarErrorMessage != nil },
                set: { if !$0 { avatarErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(avatarErrorMessage ?? "")
        }
        // The preview above the picker must draw what the picker unlocked.
        .environment(\.grovePremiumAvatarsUnlocked, premium.isUnmetered)
        .sheet(isPresented: $showingPremiumAvatarPaywall) {
            AskPaywallSheet(reason: .profileAvatar)
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await loadAvatar(from: item) }
        }
        .onAppear {
            guard !didLoad else { return }
            name = store.profile.name
            username = store.profile.username
            regionCode = store.profile.regionCode ?? regionCode
            usesMetricSystem = store.profile.usesMetricSystem ?? usesMetricSystem
            selectedAvatarAssetName = store.profile.avatarAssetName
            existingAvatarPhotoURL = GroveMediaPath.resolved(store.profile.avatarPhotoURL)
            avatarPage = AvatarView.pageIndex(
                for: selectedAvatarAssetName ?? defaultAvatarAssetName
            )
            didLoad = true
            if name.isEmpty { focusedField = .name }
            else if username.isEmpty { focusedField = .username }
        }
        .task { await premium.load() }
    }

    // MARK: - Save

    /// The page's committing action, docked rather than sitting in a final form
    /// row. As a row it read as a link and, during onboarding, sat below an
    /// avatar carousel and four sections — the one control the flow depends on
    /// was the one you had to go looking for.
    private var saveBar: some View {
        VStack(spacing: 10) {
            if let saveBlockerReason {
                Text(saveBlockerReason)
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }

            Button {
                save()
            } label: {
                GroveCTALabel(
                    title: isOnboarding ? "Take me to my grove" : "Save profile",
                    systemImage: isOnboarding ? "arrow.right" : "checkmark"
                )
            }
            .buttonStyle(GrovePressStyle())
            .disabled(!canSave)
            // Dims the button, not the bar: applied after `groveActionBar` the
            // opacity would fade the gradient the bar uses to dissolve into the
            // canvas, and the page would appear to lift off its own background.
            .opacity(canSave ? 1 : 0.4)
            .accessibilityIdentifier("saveProfile")
        }
        .animation(GroveMotion.snap, value: canSave)
        .animation(GroveMotion.snap, value: saveBlockerReason)
        .groveActionBar()
    }

    /// Why the button is dim, in one line, directly above it. This is the only
    /// place the rules are spelled out: a copy of them under the username field
    /// meant the same sentence appeared twice on a screen this short.
    private var saveBlockerReason: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add a display name."
        }
        if hasBlockedProfileLanguage {
            return "Choose a display name that is respectful to other gardeners."
        }
        if normalizedUsername.isEmpty {
            return "Pick a username."
        }
        if !isUsernameValid {
            return "Usernames are 3 to 24 lowercase letters, numbers, or underscores."
        }
        if regionCode.trimmingCharacters(in: .whitespacesAndNewlines).count != 2 {
            return "Choose your region."
        }
        return nil
    }

    @ViewBuilder
    private func avatarPageContent(_ pageIndex: Int) -> some View {
        if pageIndex == AvatarView.premiumPageIndex {
            VStack(spacing: 6) {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 12),
                        count: 4
                    ),
                    spacing: 12
                ) {
                    ForEach(AvatarView.imagePages[pageIndex], id: \.self) { assetName in
                        avatarOption(assetName)
                    }
                }
                Text("Grove Premium · exclusive mascots")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GroveTheme.mutedInk)
            }
            .frame(maxWidth: .infinity)
        } else {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 12),
                    count: 4
                ),
                spacing: 14
            ) {
                ForEach(AvatarView.imagePages[pageIndex], id: \.self) { assetName in
                    avatarOption(assetName)
                }
            }
        }
    }

    private var avatarPickerHeight: CGFloat {
        avatarPage == AvatarView.premiumPageIndex ? 220 : 122
    }

    private func avatarPageAccessibilityLabel(_ pageIndex: Int) -> String {
        let title = pageIndex == AvatarView.premiumPageIndex
            ? "Grove Premium profile pictures"
            : "Profile pictures"
        return "\(title), page \(pageIndex + 1) of \(AvatarView.imagePages.count)"
    }

    private var normalizedUsername: String {
        username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
    }

    private var isUsernameValid: Bool {
        (3...24).contains(normalizedUsername.count)
            && normalizedUsername.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !hasBlockedProfileLanguage
            && isUsernameValid
            && regionCode.trimmingCharacters(in: .whitespacesAndNewlines).count == 2
    }

    private var hasBlockedProfileLanguage: Bool {
        let blocked = Set(["cunt", "faggot", "fag", "kike", "nigger", "nigga", "retard", "whore"])
        let words = name.precomposedStringWithCompatibilityMapping
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return words.contains { blocked.contains($0) }
    }

    private var defaultAvatarAssetName: String {
        AvatarView.defaultImageName
    }

    private var hasCustomAvatar: Bool {
        customAvatarImage != nil || existingAvatarPhotoURL != nil
    }

    @ViewBuilder
    private var profileAvatarPreview: some View {
        if let customAvatarImage {
            Image(uiImage: customAvatarImage)
                .resizable()
                .scaledToFill()
                .frame(width: 104, height: 104)
                .clipShape(Circle())
                .overlay { Circle().stroke(GroveTheme.accent, lineWidth: 3) }
                .accessibilityLabel("Selected custom profile photo")
        } else {
            AvatarView(
                initials: store.profile.initials,
                seed: store.activeAccountID ?? store.profile.username,
                size: 104,
                assetName: selectedAvatarAssetName,
                photoURL: existingAvatarPhotoURL
            )
            .overlay { Circle().stroke(GroveTheme.accent, lineWidth: 3) }
            .accessibilityLabel("Current profile picture")
        }
    }

    /// The title is resolved by the caller and arrives as a plain `String`, so
    /// the picker's label closure captures a `Sendable` value rather than
    /// reaching back into main-actor view state from inside it.
    private func photoPicker(title: String) -> some View {
        PhotosPicker(selection: $selectedPhoto, matching: .images) {
            GroveOutlineLabel(title: title, systemImage: "photo.on.rectangle")
        }
        .buttonStyle(GrovePressStyle())
        .disabled(isLoadingAvatar)
        .accessibilityIdentifier("chooseProfilePhoto")
    }

    private func avatarOption(_ assetName: String) -> some View {
        let isPremiumAvatar = AvatarView.isPremiumAsset(assetName)
        let isLocked = isPremiumAvatar && !premium.isUnmetered
        let isSelected = !isLocked && !hasCustomAvatar
            && (selectedAvatarAssetName ?? defaultAvatarAssetName) == assetName
        return Button {
            if isLocked {
                showingPremiumAvatarPaywall = true
            } else {
                chooseAvatar(assetName)
            }
        } label: {
            ZStack {
                Image(assetName)
                    .resizable()
                    .scaledToFill()
                    .opacity(isLocked ? 0.62 : 1)
                if isLocked {
                    Circle()
                        .fill(.black.opacity(0.28))
                    Image(systemName: "lock.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(7)
                        .background(GroveTheme.accentStrong, in: Circle())
                }
            }
                .frame(width: 54, height: 54)
                .clipShape(Circle())
                .overlay {
                    Circle().stroke(
                        isSelected
                            ? GroveTheme.accent
                            : isLocked
                                ? GroveTheme.accentStrong.opacity(0.72)
                                : GroveTheme.separator,
                        lineWidth: isSelected ? 3 : 1
                    )
                }
                .overlay(alignment: .bottomTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.black))
                            .foregroundStyle(GroveTheme.onAccent)
                            .frame(width: 20, height: 20)
                            .background(GroveTheme.accent, in: Circle())
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isLocked
                ? "Unlock \(avatarDisplayName(assetName)) with Grove Premium"
                : "Use \(avatarDisplayName(assetName)) avatar"
        )
        .accessibilityHint(isLocked ? "Opens Grove Premium subscription options" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func chooseAvatar(_ assetName: String) {
        selectedAvatarAssetName = assetName
        avatarPage = AvatarView.pageIndex(for: assetName)
        existingAvatarPhotoURL = nil
        customAvatarImage = nil
        customAvatarData = nil
        selectedPhoto = nil
    }

    private func avatarDisplayName(_ assetName: String) -> String {
        switch assetName {
        case "GroveAvatarPremiumMoonlitMonstera":
            return "Moonlit monstera premium mascot"
        case "GroveAvatarPremiumOrchid":
            return "Jewel orchid premium mascot"
        case "GroveAvatarPremiumVelvetCalathea":
            return "Velvet calathea premium mascot"
        case "GroveAvatarPremiumStarlightStringOfHearts":
            return "Starlight string of hearts premium mascot"
        case "GroveAvatarPremiumRosewaterHoya":
            return "Rosewater hoya premium mascot"
        case "GroveAvatarPremiumSilverMoonAlocasia":
            return "Silver moon alocasia premium mascot"
        case "GroveAvatarPremiumEmberBegonia":
            return "Ember begonia premium mascot"
        case "GroveAvatarPremiumGildedGinkgo":
            return "Gilded ginkgo premium mascot"
        case "GroveAvatarPremiumSunsetBirdOfParadise":
            return "Sunset bird of paradise premium mascot"
        case "GroveAvatarPremiumFrostedAnthurium":
            return "Frosted anthurium premium mascot"
        default:
            break
        }
        let rawName = assetName
            .replacingOccurrences(of: "GroveAvatar", with: "")
        let isMascot = rawName.hasPrefix("Mascot")
        var name = isMascot ? String(rawName.dropFirst("Mascot".count)) : rawName
        name = name.replacingOccurrences(of: "SnakePlant", with: "Snake plant")
        return isMascot ? "\(name) mascot" : name
    }

    private func loadAvatar(from item: PhotosPickerItem) async {
        isLoadingAvatar = true
        defer { isLoadingAvatar = false }
        do {
            guard let sourceData = try await item.loadTransferable(type: Data.self),
                  let preparedData = Self.preparedAvatarData(sourceData),
                  let image = UIImage(data: preparedData)
            else {
                throw ProfileAvatarError.invalidImage
            }
            customAvatarData = preparedData
            customAvatarImage = image
            selectedAvatarAssetName = nil
            existingAvatarPhotoURL = nil
        } catch {
            selectedPhoto = nil
            avatarErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? "That photo could not be read. Try choosing another one."
        }
    }

    /// Squares and downsamples the selected image before persistence. Encoding
    /// the rendered pixels also removes embedded location and camera metadata.
    private static func preparedAvatarData(_ sourceData: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else { return nil }

        let maxDimension: CGFloat = 1_024
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }

        let width = CGFloat(thumbnail.width)
        let height = CGFloat(thumbnail.height)
        let side = min(width, height)
        let cropRect = CGRect(
            x: (width - side) / 2,
            y: (height - side) / 2,
            width: side,
            height: side
        )
        guard side > 0,
              let cropped = thumbnail.cropping(to: cropRect.integral)
        else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            cropped,
            [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private func save() {
        guard canSave else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRegion = regionCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let assetName = selectedAvatarAssetName.map { selected in
            AvatarView.isPremiumAsset(selected) && !premium.isUnmetered
                ? defaultAvatarAssetName
                : selected
        }
        do {
            try store.updateProfileAvatar(
                assetName: assetName,
                existingPhotoURL: existingAvatarPhotoURL,
                customImageData: customAvatarData
            )
        } catch {
            avatarErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Grove couldn't save that profile photo. Try again."
            return
        }
        store.updateProfile(
            name: trimmedName,
            username: normalizedUsername,
            regionCode: normalizedRegion,
            usesMetricSystem: usesMetricSystem,
            isPrivate: true
        )
        // The pinned grove location rides along untouched. `PATCH /profile`
        // writes all three location columns on every call, so a name or privacy
        // edit that omitted them erased the pin on the server — and the next
        // bootstrap, which assigns the remote profile wholesale, then cleared it
        // on this iPhone too and asked for the location again.
        let location = store.profile.location
        let request = UpdateProfileRequest(
            displayName: trimmedName,
            username: normalizedUsername,
            regionCode: normalizedRegion,
            usesMetricSystem: usesMetricSystem,
            isPrivate: true,
            latitude: location?.latitude,
            longitude: location?.longitude,
            locationLabel: location?.label,
            locationCountryCode: location?.countryCode,
            locationTimeZoneIdentifier: location?.timeZoneIdentifier,
            clientRequestID: UUID()
        )
        Task { await syncEngine.enqueue(.updateProfile(request), isConnected: connectivity.isConnected) }
        if !isOnboarding { dismiss() }
    }

    private enum Field {
        case name
        case username
    }
}
