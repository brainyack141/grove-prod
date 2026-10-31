import SwiftUI

/// One country or territory the user can set as their region, carrying the flag
/// and the name already resolved for the device's language.
struct GroveRegionOption: Identifiable, Hashable {
    /// ISO 3166-1 alpha-2, uppercased. This is what the backend and the
    /// analysis gateway see.
    let code: String
    let name: String
    let flag: String

    var id: String { code }
}

/// The list of regions the picker offers, built once from the system's own ISO
/// table so it stays current with the OS rather than with a hand-kept array.
enum GroveRegionCatalog {
    /// Every ISO alpha-2 region, sorted by localized name.
    static let all: [GroveRegionOption] = {
        Locale.Region.isoRegions
            .map(\.identifier)
            .filter(isFlaggableCountryCode)
            .compactMap(option(for:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    private static let byCode: [String: GroveRegionOption] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.code, $0) }
    )

    /// The catalog entry for a stored code, or a best-effort stand-in so a code
    /// Grove has never heard of still shows something a person can read.
    static func option(matching code: String?) -> GroveRegionOption? {
        guard let code else { return nil }
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.count == 2 else { return nil }
        if let known = byCode[normalized] { return known }
        return GroveRegionOption(code: normalized, name: normalized, flag: flag(for: normalized))
    }

    /// The device's own region, when it is one Grove can offer.
    static var deviceOption: GroveRegionOption? {
        option(matching: Locale.current.region?.identifier)
    }

    static func matches(_ option: GroveRegionOption, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return option.name.range(of: trimmed, options: options) != nil
            || option.code.range(of: trimmed, options: options) != nil
    }

    // ISO's table also carries groupings (numeric continent codes), the private
    // -use codes, and supranational entries. None of them are somewhere a plant
    // grows, and none have a flag, so they never reach the list.
    private static let nonCountryCodes: Set<String> = ["EU", "EZ", "UN", "QO", "ZZ", "XA", "XB", "XK"]

    private static func isFlaggableCountryCode(_ code: String) -> Bool {
        code.count == 2
            && code.allSatisfy { $0.isASCII && $0.isLetter }
            && !nonCountryCodes.contains(code.uppercased())
    }

    private static func option(for code: String) -> GroveRegionOption? {
        let normalized = code.uppercased()
        // No localized name means the OS does not really know this code; showing
        // the raw letters in a country list would just read as a bug.
        guard let name = Locale.current.localizedString(forRegionCode: normalized),
              name != normalized
        else { return nil }
        return GroveRegionOption(code: normalized, name: name, flag: flag(for: normalized))
    }

    /// Two ASCII letters map to the two regional-indicator symbols that render
    /// as that country's flag.
    private static func flag(for code: String) -> String {
        let base: UInt32 = 0x1F1E6
        var flag = ""
        for scalar in code.uppercased().unicodeScalars {
            guard let indicator = UnicodeScalar(base + scalar.value - 65) else { return "🏳️" }
            flag.unicodeScalars.append(indicator)
        }
        return flag.isEmpty ? "🏳️" : flag
    }
}

/// The region row inside a Form: the flag and country name as the current
/// value, tapping opens the full list.
struct GroveRegionRow: View {
    @Binding var code: String

    @State private var isPickerPresented = false

    private var selection: GroveRegionOption? {
        GroveRegionCatalog.option(matching: code)
    }

    var body: some View {
        Button {
            Haptics.press()
            isPickerPresented = true
        } label: {
            HStack(spacing: 12) {
                Text("Region")
                    .foregroundStyle(GroveTheme.ink)
                Spacer(minLength: 12)
                if let selection {
                    Text(selection.flag)
                        .font(.title3)
                        .accessibilityHidden(true)
                    Text(selection.name)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .lineLimit(1)
                } else {
                    Text("Choose")
                        .foregroundStyle(GroveTheme.mutedInk)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GroveTheme.subtleInk)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profileRegion")
        .accessibilityLabel("Region")
        .accessibilityValue(selection?.name ?? "Not set")
        .accessibilityHint("Opens the country list")
        .sheet(isPresented: $isPickerPresented) {
            GroveRegionPickerSheet(code: $code)
        }
    }
}

/// The searchable country list. Long enough that search is the primary way in,
/// so the field is up front and the current pick is scrolled to on open.
struct GroveRegionPickerSheet: View {
    @Binding var code: String
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""

    private var results: [GroveRegionOption] {
        GroveRegionCatalog.all.filter { GroveRegionCatalog.matches($0, query: query) }
    }

    private var suggestion: GroveRegionOption? {
        guard query.isEmpty,
              let device = GroveRegionCatalog.deviceOption,
              device.code != code.uppercased()
        else { return nil }
        return device
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if let suggestion {
                        Section("From your phone") {
                            row(suggestion)
                        }
                    }

                    if results.isEmpty {
                        Section {
                            Text("No country matches “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                                .foregroundStyle(GroveTheme.mutedInk)
                        }
                    } else {
                        Section {
                            ForEach(results) { option in
                                row(option)
                            }
                        }
                    }
                }
                .groveGroupedContent()
                .onAppear {
                    guard let current = GroveRegionCatalog.option(matching: code) else { return }
                    proxy.scrollTo(current.id, anchor: .center)
                }
            }
            .searchable(text: $query, prompt: "Country or region")
            .autocorrectionDisabled()
            .grovePageTitle("Region")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func row(_ option: GroveRegionOption) -> some View {
        let isSelected = option.code == code.uppercased()
        return Button {
            Haptics.toggle(on: true)
            code = option.code
            dismiss()
        } label: {
            HStack(spacing: 14) {
                Text(option.flag)
                    .font(.title2)
                    .accessibilityHidden(true)
                Text(option.name)
                    .foregroundStyle(GroveTheme.ink)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(GroveTheme.accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .id(option.id)
        .accessibilityLabel(option.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview {
    @Previewable @State var code = "NZ"
    NavigationStack {
        Form {
            Section("Region and measurements") {
                GroveRegionRow(code: $code)
            }
        }
        .formStyle(.grouped)
        .groveGroupedContent()
    }
}
