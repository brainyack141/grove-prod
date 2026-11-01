import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// Full-screen picker that lets a user pin the exact location of their overall
/// Grove (not a single plant). The pin stays fixed at the centre of the map and
/// the map moves underneath it, mirroring the standard "drop a pin" pattern.
struct GroveLocationPickerView: View {
    @Environment(GroveStore.self) private var store
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var cameraPosition: MapCameraPosition
    @State private var centerCoordinate: CLLocationCoordinate2D
    @State private var resolvedLabel: String
    /// Captured alongside the label so the saved pin knows which country and
    /// time zone it sits in — that is what `TravelWatcher` later compares the
    /// phone against to notice the owner has left town.
    @State private var resolvedCountryCode: String?
    @State private var resolvedTimeZone: String?
    @State private var isResolving = false
    @State private var searchText = ""
    @State private var searchResults: [SearchResult] = []
    @State private var isSaving = false
    /// A new account cannot accept the map's display-only Seattle fallback as
    /// its home by tapping through. The person must search, use their current
    /// position, move the map, or return to a pin already saved in the draft.
    @State private var hasChosenPin = false
    @State private var locationManager = GroveLocationManager()

    private let geocoder = CLGeocoder()

    /// Present only while the signed-out funnel owns this picker. In that mode
    /// the chosen pin is written to the durable onboarding draft and this sheet
    /// closes back onto the Home step, which shows the town and its weather;
    /// the signed-in store and sync queue do not exist for the new account yet
    /// and must not be mutated early. Navigation stays with the Home step: the
    /// picker used to call `back()` and `advance()` on the model, which moved
    /// the funnel underneath an open sheet.
    private let onboardingModel: OnboardingModel?

    init(onboardingModel: OnboardingModel? = nil) {
        self.onboardingModel = onboardingModel
        // Seed from the previously saved Grove location, else a sensible default.
        let fallback = CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321) // Seattle
        _cameraPosition = State(initialValue: .region(
            MKCoordinateRegion(
                center: fallback,
                span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
            )
        ))
        _centerCoordinate = State(initialValue: fallback)
        _resolvedLabel = State(initialValue: "")
    }

    var body: some View {
        ZStack {
            map
            centerPin
            VStack(spacing: 0) {
                onboardingBackControl
                searchBar
                Spacer()
                locationCard
            }
        }
        .grovePageTitle(onboardingModel == nil ? "Grove location" : "Set your location")
        .toolbar {
            if onboardingModel == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
        }
        .onAppear(perform: seedFromSavedLocation)
        .onChange(of: locationManager.lastCoordinate.map { "\($0.latitude),\($0.longitude)" }) { _, _ in
            guard let coordinate = locationManager.lastCoordinate else { return }
            hasChosenPin = true
            move(to: coordinate)
        }
    }

    @ViewBuilder
    private var onboardingBackControl: some View {
        if onboardingModel != nil {
            OnboardingBackButton { dismiss() }
                .background(.regularMaterial, in: Circle())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, OnboardingTheme.pagePadding)
                .padding(.top, 8)
        }
    }

    // MARK: - Map

    private var map: some View {
        Map(position: $cameraPosition, interactionModes: [.pan, .zoom])
            .ignoresSafeArea()
            .simultaneousGesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { _ in hasChosenPin = true }
            )
            // Track the centre continuously so tapping Save mid-pan stores the
            // point actually under the pin; geocode only when the pan ends.
            .onMapCameraChange(frequency: .continuous) { context in
                centerCoordinate = context.region.center
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                centerCoordinate = context.region.center
                reverseGeocode(context.region.center)
            }
    }

    private var centerPin: some View {
        // The tip of the pin points at the exact map centre, so nudge it up by
        // half its own height.
        VStack(spacing: 2) {
            Image(systemName: "mappin")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(GroveTheme.accent)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            Circle()
                .fill(GroveTheme.accent.opacity(0.28))
                .frame(width: 8, height: 8)
        }
        .offset(y: -19)
        .allowsHitTesting(false)
    }

    // MARK: - Search

    private var searchBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(GroveTheme.mutedInk)
                TextField("Search for a place", text: $searchText)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(runSearch)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(GroveTheme.subtleInk)
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().stroke(GroveTheme.separator, lineWidth: 1) }

            if !searchResults.isEmpty {
                VStack(spacing: 0) {
                    ForEach(searchResults) { result in
                        Button {
                            Haptics.selection()
                            select(result)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "mappin.circle.fill")
                                    .foregroundStyle(GroveTheme.accent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(result.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(GroveTheme.ink)
                                    if let subtitle = result.subtitle {
                                        Text(subtitle)
                                            .font(.caption)
                                            .foregroundStyle(GroveTheme.mutedInk)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(GroveCardPressStyle(scale: 0.985, haptics: false))
                        if result.id != searchResults.last?.id {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous).stroke(GroveTheme.separator, lineWidth: 1) }
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, GroveTheme.pagePadding)
        .padding(.top, 8)
    }

    // MARK: - Bottom card

    private var locationCard: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Stay a compact card when it fits; only scroll when the
                // text no longer fits under the search bar.
                ViewThatFits(in: .vertical) {
                    locationCardContent
                        .padding(18)
                    ScrollView {
                        locationCardContent
                            .padding(18)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            } else {
                locationCardContent
                    .padding(18)
            }
        }
        .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.heroRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GroveTheme.heroRadius, style: .continuous)
                .stroke(GroveTheme.separator, lineWidth: 1)
        }
        .groveShadow(.floating)
        .padding(.horizontal, GroveTheme.pagePadding)
        .padding(.bottom, 12)
    }

    private var locationCardContent: some View {
        VStack(spacing: 14) {
            if onboardingModel != nil {
                VStack(alignment: .leading, spacing: 7) {
                    GroveDisplayHeading(
                        text: "Where does your grove live?",
                        style: .section
                    )
                    Text("Set the place where your plants stay. Grove uses it for local daylight, weather, and seasonal care.")
                        .font(.footnote)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // What the pin is for, said once, while it is being placed. Today
            // used to carry this on a card of its own, which meant the reason
            // to answer sat on a different screen from the answering.
            if onboardingModel == nil, store.profile.location == nil {
                Text("Your forecast comes from this pin: the light your plants get, and the cold nights that reach them through the glass.")
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                Image(systemName: "leaf.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(GroveTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayLabel)
                        .font(.headline)
                        .foregroundStyle(GroveTheme.ink)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(coordinateSummary)
                        .font(.caption)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if isResolving {
                    ProgressView()
                }
            }

            Button(action: locationManager.requestCurrentLocation) {
                GroveOutlineLabel(
                    title: locationManager.status == .locating ? "Finding you…" : "Use my current location",
                    systemImage: "location.fill"
                )
            }
            .buttonStyle(GrovePressStyle())

            locationNotice

            if onboardingModel != nil, !hasChosenPin {
                Text("Search for your area, use your current location, or move the map to choose your grove's home.")
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: save) {
                GroveCTALabel(
                    title: saveButtonTitle,
                    systemImage: "checkmark"
                )
            }
            .buttonStyle(GrovePressStyle())
            .disabled(!canSave)
            .opacity(canSave ? 1 : 0.4)
            .accessibilityIdentifier(
                onboardingModel == nil ? "saveGroveLocation" : "onboardingSaveLocation"
            )
        }
    }

    /// What went wrong with the last "use my current location", and the way out.
    ///
    /// Both cases name the search field as the alternative, because it is the
    /// one route to a correct pin that needs no permission at all — and someone
    /// standing in the place they are trying to pin can always type it.
    @ViewBuilder
    private var locationNotice: some View {
        switch locationManager.status {
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                Text("Grove doesn't have permission to use your location. You can turn it on in Settings, or search for the place above.")
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                }
                .font(.footnote.weight(.bold))
                .foregroundStyle(GroveTheme.accentStrong)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .failed:
            Text("Couldn't get a location fix just now. Try again, or search for the place above.")
                .font(.footnote)
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .idle, .locating:
            EmptyView()
        }
    }

    private var displayLabel: String {
        if !resolvedLabel.isEmpty { return resolvedLabel }
        return isResolving ? "Finding place…" : "Dropped pin"
    }

    private var coordinateSummary: String {
        String(format: "%.4f, %.4f", centerCoordinate.latitude, centerCoordinate.longitude)
    }

    private var saveButtonTitle: String {
        if isSaving { return "Saving…" }
        return onboardingModel == nil ? "Save this location" : "Use this location"
    }

    private var canSave: Bool {
        !isSaving && (onboardingModel == nil || hasChosenPin)
    }

    // MARK: - Actions

    private func seedFromSavedLocation() {
        let saved = onboardingModel?.location
            ?? (onboardingModel == nil ? store.profile.location : nil)
        guard let saved else {
#if DEBUG
            // Provider UI cannot be automated, so the deterministic onboarding
            // test route also needs a deterministic accepted pin.
            if ProcessInfo.processInfo.arguments.contains("-GroveUITestOnboardingSample") {
                hasChosenPin = true
            }
#endif
            reverseGeocode(centerCoordinate)
            return
        }
        hasChosenPin = true
        centerCoordinate = saved.coordinate
        resolvedLabel = saved.label
        resolvedCountryCode = saved.countryCode
        resolvedTimeZone = saved.timeZoneIdentifier
        cameraPosition = .region(
            MKCoordinateRegion(
                center: saved.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
            )
        )
    }

    private func move(to coordinate: CLLocationCoordinate2D) {
        centerCoordinate = coordinate
        withAnimation {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                )
            )
        }
        reverseGeocode(coordinate)
    }

    private func runSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(
            center: centerCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 20, longitudeDelta: 20)
        )
        MKLocalSearch(request: request).start { response, _ in
            let results = (response?.mapItems ?? []).prefix(6).map { item in
                SearchResult(
                    title: item.name ?? item.placemark.title ?? "Location",
                    subtitle: Self.subtitle(for: item.placemark),
                    coordinate: item.placemark.coordinate
                )
            }
            Task { @MainActor in searchResults = Array(results) }
        }
    }

    private func select(_ result: SearchResult) {
        hasChosenPin = true
        searchResults = []
        searchText = result.title
        resolvedLabel = result.subtitle.map { "\(result.title), \($0)" } ?? result.title
        move(to: result.coordinate)
    }

    private func reverseGeocode(_ coordinate: CLLocationCoordinate2D) {
        isResolving = true
        geocoder.cancelGeocode()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        geocoder.reverseGeocodeLocation(location) { placemarks, _ in
            Task { @MainActor in
                isResolving = false
                guard let placemark = placemarks?.first else {
                    // Keeping the previous place's label would save the new
                    // coordinates under the old city's name; fall back to the
                    // coordinate summary instead. The country and time zone go
                    // with it, for the same reason.
                    resolvedLabel = ""
                    resolvedCountryCode = nil
                    resolvedTimeZone = nil
                    return
                }
                resolvedLabel = Self.label(for: placemark)
                resolvedCountryCode = placemark.isoCountryCode
                resolvedTimeZone = placemark.timeZone?.identifier
            }
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        let label = resolvedLabel.isEmpty ? coordinateSummary : resolvedLabel
        let location = GroveLocation(
            coordinate: centerCoordinate,
            label: label,
            countryCode: resolvedCountryCode,
            timeZoneIdentifier: resolvedTimeZone
        )

        if let onboardingModel {
            onboardingModel.location = location
            onboardingModel.persistDraft()
            isSaving = false
            dismiss()
            return
        }

        store.updateGroveLocation(location)

        let profile = store.profile
        let request = UpdateProfileRequest(
            displayName: profile.name,
            username: profile.username,
            regionCode: profile.regionCode ?? "",
            usesMetricSystem: profile.usesMetricSystem ?? true,
            isPrivate: profile.isPrivate ?? true,
            latitude: location.latitude,
            longitude: location.longitude,
            locationLabel: location.label,
            locationCountryCode: location.countryCode,
            locationTimeZoneIdentifier: location.timeZoneIdentifier,
            clientRequestID: UUID()
        )
        Task {
            await syncEngine.enqueue(.updateProfile(request), isConnected: connectivity.isConnected)
            isSaving = false
            dismiss()
        }
    }

    // MARK: - Label helpers

    private static func label(for placemark: CLPlacemark) -> String {
        let city = placemark.locality ?? placemark.subAdministrativeArea ?? placemark.administrativeArea
        let country = placemark.country
        switch (city, country) {
        case let (city?, country?): return "\(city), \(country)"
        case let (city?, nil): return city
        case let (nil, country?): return country
        default: return placemark.name ?? "Dropped pin"
        }
    }

    private static func subtitle(for placemark: MKPlacemark) -> String? {
        let parts = [placemark.locality, placemark.administrativeArea, placemark.country]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    struct SearchResult: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String?
        let coordinate: CLLocationCoordinate2D
    }
}

/// Thin wrapper around CLLocationManager for the one-shot "use my current
/// location" button.
@Observable
final class GroveLocationManager: NSObject, CLLocationManagerDelegate {
    /// What became of the last request the *user* made.
    ///
    /// It starts idle and only leaves idle when the button is pressed, which is
    /// what keeps two unrelated things from happening on their own: a picker
    /// that opens showing a permission error to somebody who refused location
    /// months ago and has not asked for anything, and — the older bug — a picker
    /// that quietly drags the pin off the saved grove and onto the phone.
    /// Setting a `CLLocationManager` delegate makes iOS deliver an authorisation
    /// callback immediately, and that callback used to fetch a position and move
    /// the map, so opening the picker while abroad re-pinned the grove to
    /// wherever its owner happened to be standing.
    enum Status: Equatable {
        case idle
        case locating
        case denied
        case failed
    }

    var lastCoordinate: CLLocationCoordinate2D?
    private(set) var status: Status = .idle

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestCurrentLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            status = .locating
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            status = .locating
            manager.requestLocation()
        default:
            // Previously a silent no-op, which is the worst available answer:
            // the one control that repairs a wrong location did nothing at all,
            // and said nothing about why.
            status = .denied
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard status == .locating else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            status = .denied
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        status = .idle
        lastCoordinate = coordinate
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard status == .locating else { return }
        status = .failed
    }
}

#Preview {
    NavigationStack { GroveLocationPickerView() }
        .environment(GroveStore())
        .environment(SyncEngine(queueStore: MutationQueueStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("GroveLocationPreviewQueue.json"))))
        .environment(ConnectivityMonitor())
}
