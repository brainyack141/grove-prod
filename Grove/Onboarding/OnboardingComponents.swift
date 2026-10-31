import SwiftUI

// `OnboardingAuthMethod` is declared alongside `SessionService`.

// MARK: - Theme

/// The illustrated first-run palette retains Grove's semantic ink and controls.
/// Paper and forest are scoped here so the rest of the app keeps its own canvas.
enum OnboardingTheme {
    /// The page behind every first-run sheet. It used to be a scoped cream;
    /// the photo-and-sheet direction sets onboarding on Grove's own canvas so
    /// the first screen and Today read as one app.
    static let base = GroveTheme.background
    /// The raised sheet on the welcome screen and the account gate.
    static let sheet = GroveTheme.surface
    /// Primary controls and selected choices are filled with ink; this is the
    /// type that sits on that fill.
    static let inkFill = GroveTheme.ink
    static let onInk = GroveTheme.background
    static let forest = GroveTheme.adaptive(light: 0x31593A, dark: 0x193B29)
    static let onForest = Color(red: 0.98, green: 0.97, blue: 0.93)
    static let onForestMuted = Color(red: 0.82, green: 0.88, blue: 0.80)
    static let elevated = GroveTheme.surface
    static let elevatedStrong = GroveTheme.secondarySurface
    static let stroke = GroveTheme.separator
    static let strokeStrong = GroveTheme.subtleInk
    static let ink = GroveTheme.ink
    static let mutedInk = GroveTheme.mutedInk
    static let subtleInk = GroveTheme.subtleInk
    static let accent = GroveTheme.accent
    /// Deeper green for green text on the cream canvas — `accent` alone falls
    /// short of comfortable text contrast there.
    static let accentStrong = GroveTheme.accentStrong
    static let accentSoft = GroveTheme.softAccent
    static let danger = GroveTheme.danger

    static let controlRadius: CGFloat = GroveTheme.pillRadius
    static let cardRadius: CGFloat = GroveTheme.cardRadius
    static let rowRadius: CGFloat = GroveTheme.insetRadius
    static let pagePadding: CGFloat = GroveTheme.pagePadding
    static let controlHeight: CGFloat = 58
    static let choiceHeight: CGFloat = 60
    static let sheetRadius: CGFloat = GroveTheme.heroRadius
}

/// Quiet sky behind the content, with the illustrated garden at the foot.
/// Dark appearance lowers the artwork's luminance behind semantic light ink.
struct OnboardingBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            OnboardingTheme.base
                .overlay {
                    Image("OnboardingGardenLandscape")
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .opacity(colorScheme == .dark ? 0.14 : 0.72)
                }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Artwork remains decorative; Grove's existing mark supplies the identity.
struct OnboardingGardenIllustration: View {
    var body: some View {
        Image("OnboardingGardenHero")
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: GroveTheme.heroRadius, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Scaffold

/// Standard chrome for a personalization step over the cream canvas: a back
/// chevron, a scrollable body, and the committing action docked at the foot.
///
/// Progress stays out of the shared scaffold. Only the manual fallback has a
/// multi-question sequence, and that sequence renders its own quiet indicator;
/// scan-first and authentication screens are single-purpose destinations.
struct OnboardingScaffold<Content: View, Footer: View>: View {
    var showsBack: Bool = true
    var onBack: () -> Void = {}
    /// Steps where the answer is the action have no docked button. The bar is
    /// dropped rather than left empty, so its scrim and padding don't reserve a
    /// strip of page for a control that isn't there.
    var showsFooter: Bool = true
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        ZStack {
            OnboardingBackground()
            VStack(spacing: 0) {
                if showsBack {
                    OnboardingBackButton(action: onBack)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, OnboardingTheme.pagePadding)
                }

                ScrollView {
                    content()
                        .padding(.horizontal, OnboardingTheme.pagePadding)
                        .padding(.top, showsBack ? 12 : 28)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                // A question that fits has nothing to scroll, and rubber-banding
                // a static page is the tell that it was laid out by a container
                // rather than designed.
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
                // Docked, so the answer and the way forward stay on one screen
                // with the keyboard up, and content dissolves into the canvas
                // beneath the button instead of ending at a rule.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if showsFooter {
                        footer().groveActionBar()
                    }
                }
            }
        }
    }
}

/// The way back: a bare chevron on a 44pt target, aligned to the same margin as
/// the question below it.
///
/// It used to be a bordered white disc — a control with a surface, a stroke and
/// a radius, spent on the least important thing on the page. Onboarding's only
/// signature control is the green pill at the foot; a second treatment competing
/// with it at the top made every step look like it had two actions.
struct OnboardingBackButton: View {
    var isEnabled: Bool = true
    var tint: Color = OnboardingTheme.ink
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(tint)
                // Leading-aligned inside a full-size target: the glyph lands on
                // the text margin while the tap area stays 44×44.
                .frame(width: 44, height: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        // The chevron's point reads as indented at the true margin; two back
        // out puts its optical edge where the headline starts.
        .padding(.leading, -2)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel("Back")
        .accessibilityIdentifier("onboardingBack")
    }
}

// MARK: - Step header

/// Where the person is in a short sequence: one capsule per step, done steps
/// filled with ink, then a small-caps count above the question.
struct OnboardingStepProgress: View {
    let current: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 6) {
                ForEach(0..<max(1, total), id: \.self) { index in
                    Capsule()
                        .fill(index < current ? OnboardingTheme.inkFill : OnboardingTheme.stroke)
                        .frame(maxWidth: .infinity)
                        .frame(height: 4)
                }
            }
            Text("\(current) of \(total)".uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(OnboardingTheme.subtleInk)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current) of \(total)")
        .padding(.bottom, 8)
    }
}

struct OnboardingStepHeader: View {
    var eyebrow: String? = nil
    let title: String
    var subtitle: String?
    /// Full-page steps ask one question and should ask it at page-identity
    /// scale. The auth sheets sit above a raised keyboard with a field and a
    /// button below them, so they step down to `.heading` rather than spending
    /// the sheet's height on type.
    var titleStyle: GroveDisplayStyle = .title
    /// Space between the header block and the content below. Quiz steps use
    /// the default; screens that provide their own rhythm pass a smaller value
    /// instead of patching with negative padding.
    var bottomPadding: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let eyebrow {
                Text(eyebrow)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OnboardingTheme.accentStrong)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)
            }
            Text(title)
                .font(titleStyle == .heading ? .title2.weight(.bold) : .largeTitle.weight(.bold))
                .foregroundStyle(OnboardingTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(OnboardingTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, bottomPadding)
    }
}

// MARK: - Choice row

/// One answer to a quiz question. Unselected rows are quiet white plates;
/// the chosen row fills with ink and carries a check, so the answer is the
/// darkest thing on the page.
///
/// `artworkName` and `systemImage` are still accepted so the catalogue stays
/// the single source of each option, but the row no longer draws them: the
/// hero photo above carries the mood, and the answers read faster as type.
struct OnboardingChoiceRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    var detail: String?
    var artworkName: String?
    var systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: OnboardingTheme.rowRadius, style: .continuous)
    }

    private var titleColor: Color {
        isSelected ? OnboardingTheme.onInk : OnboardingTheme.ink
    }

    private var detailColor: Color {
        isSelected ? OnboardingTheme.onInk.opacity(0.72) : OnboardingTheme.mutedInk
    }

    private var fill: Color {
        isSelected ? OnboardingTheme.inkFill : OnboardingTheme.elevated
    }

    private var edge: Color {
        isSelected ? OnboardingTheme.inkFill : OnboardingTheme.stroke
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(titleColor)
                    if let detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(detailColor)
                    }
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.bold))
                        .foregroundStyle(OnboardingTheme.onInk)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: OnboardingTheme.choiceHeight, alignment: .leading)
            .background(fill, in: shape)
            .overlay { shape.stroke(edge, lineWidth: 1.5) }
            .contentShape(shape)
            // Onboarding is the app's first impression, so the choice a
            // user makes there should land rather than blink.
            .animation(reduceMotion ? nil : GroveMotion.pop, value: isSelected)
        }
        .buttonStyle(GroveCardPressStyle(scale: 0.985, haptics: false))
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Buttons

/// The ink capsule every first-run screen commits with: 58pt tall, full width,
/// light type. One treatment for the one action that moves the person on.
struct OnboardingInkCapsuleLabel: View {
    let title: String
    var isWorking: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if isWorking {
                ProgressView()
                    .tint(OnboardingTheme.onInk)
            }
        }
        .foregroundStyle(OnboardingTheme.onInk)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: OnboardingTheme.controlHeight)
        .background(OnboardingTheme.inkFill, in: Capsule())
        .contentShape(Capsule())
    }
}

/// The secondary capsule: the same footprint as the primary, drawn as an
/// outline so the pair reads as "this, or that" without competing.
struct OnboardingOutlineCapsuleLabel: View {
    let title: String
    var systemImage: String?
    var assetImage: String?

    var body: some View {
        HStack(spacing: 10) {
            if let assetImage {
                Image(assetImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 19, height: 19)
                    .accessibilityHidden(true)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(OnboardingTheme.ink)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: OnboardingTheme.controlHeight)
        .overlay { Capsule().stroke(OnboardingTheme.stroke, lineWidth: 1.5) }
        .contentShape(Capsule())
    }
}

/// Onboarding's primary call to action.
struct OnboardingPrimaryButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            OnboardingInkCapsuleLabel(title: title)
        }
        .buttonStyle(GrovePressStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isEnabled)
    }
}

// MARK: - Photo and sheet

/// The first-run page: a full-bleed photograph owns the top of the screen and
/// a sheet rises over its lower edge to hold the words and the choices.
///
/// The photo scrolls with the content rather than sitting fixed behind it, so
/// at large Dynamic Type sizes and on a 4.7-inch screen the page simply
/// scrolls instead of the sheet covering the image or clipping its type.
/// The footer docks at the foot on the sheet's own colour.
struct OnboardingPhotoSheet<Hero: View, Content: View, Footer: View>: View {
    /// Photo height below the status bar.
    var heroHeight: CGFloat
    /// How far the sheet rises over the photo's lower edge.
    var overlap: CGFloat = 30
    var sheetColor: Color = OnboardingTheme.base
    var showsBack: Bool = false
    var isBackEnabled: Bool = true
    var showsFooter: Bool = true
    @ViewBuilder var hero: () -> Hero
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer
    /// Declared after the view builders on purpose: the memberwise
    /// initialiser takes parameters in declaration order, so the unlabelled
    /// trailing closure always lands on `hero`. Pass it as a labelled
    /// trailing closure (`onBack: { ... }`) after `footer:`.
    var onBack: () -> Void = {}

    private var sheetShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: OnboardingTheme.sheetRadius,
            topTrailingRadius: OnboardingTheme.sheetRadius,
            style: .continuous
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    hero()
                        .frame(width: proxy.size.width, height: heroHeight + proxy.safeAreaInsets.top)
                        .clipped()
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 0) {
                        content()
                    }
                    .padding(.horizontal, OnboardingTheme.pagePadding)
                    .padding(.top, 26)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(sheetColor, in: sheetShape)
                    .shadow(color: GroveTheme.shadow, radius: 18, y: -6)
                    .padding(.top, -overlap)
                }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .background(sheetColor)
            .ignoresSafeArea(edges: .top)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsFooter {
                    VStack(spacing: 0) {
                        footer()
                    }
                    .padding(.horizontal, OnboardingTheme.pagePadding)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
                    .background(sheetColor)
                }
            }
        }
        // On the reader, which keeps the safe area, so the chevron sits below
        // the status bar while the photo runs behind it.
        .overlay(alignment: .topLeading) {
            if showsBack {
                OnboardingPhotoBackButton(isEnabled: isBackEnabled, action: onBack)
                    .padding(.leading, OnboardingTheme.pagePadding - 4)
                    .padding(.top, 4)
            }
        }
        .background(sheetColor.ignoresSafeArea())
    }
}

/// A photograph used as a first-run hero. Filled, never letterboxed.
struct OnboardingHeroPhoto: View {
    let name: String

    var body: some View {
        Color.clear
            .overlay {
                Image(name)
                    .resizable()
                    .scaledToFill()
            }
            .clipped()
            .accessibilityHidden(true)
    }
}

/// The way back when it sits on a photograph: the same chevron on a frosted
/// disc, so it reads against any image without becoming a second action.
struct OnboardingPhotoBackButton: View {
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(OnboardingTheme.ink)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(GroveCardPressStyle(scale: 0.94, haptics: false))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel("Back")
        .accessibilityIdentifier("onboardingBack")
    }
}

/// A row of quiet text links under the capsules. Falls back to a column when
/// Dynamic Type makes one line too wide.
struct OnboardingLinkRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) { content() }
            VStack(spacing: 2) { content() }
        }
        .font(.subheadline.weight(.medium))
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Legal

/// "By continuing you agree…" line with tappable Terms and Privacy links. The
/// URLs live in `GroveLegal`; Settings › Support links the same two.
struct OnboardingLegalFooter: View {
    /// Overridden by the welcome scene, which sets its type against a dark
    /// full-bleed image rather than the cream canvas.
    var tint: Color = OnboardingTheme.mutedInk

    var body: some View {
        Text(legalText)
        .font(.caption2)
        .foregroundStyle(tint)
        .tint(tint)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var legalText: AttributedString {
        var value = AttributedString("By continuing you agree to Apple's ")
        var terms = AttributedString("Standard EULA")
        terms.link = OnboardingLegal.termsURL
        terms.underlineStyle = .single
        value.append(terms)
        value.append(AttributedString(" and our "))
        var privacy = AttributedString("Privacy Policy")
        privacy.link = OnboardingLegal.privacyURL
        privacy.underlineStyle = .single
        value.append(privacy)
        value.append(AttributedString("."))
        return value
    }
}

// MARK: - Input chrome

/// Rounded input surface used by onboarding text fields.
/// A line of entry sitting on a hairline rule, in the display voice.
///
/// This replaces a boxed, bordered field: a box makes a one-word answer look
/// like paperwork and caps the type at form scale. On a rule the answer can be
/// set at headline size in the display face, so the step reads as signing your name
/// rather than filling in a form. The rule inks over in accent on focus, which
/// is the only focus affordance the line needs.
struct OnboardingRuleField<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isFocused: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(OnboardingTheme.stroke)
                    .frame(height: 1)
                Capsule()
                    .fill(OnboardingTheme.accentStrong)
                    .frame(height: 2)
                    .opacity(isFocused ? 1 : 0)
                    .scaleEffect(x: isFocused ? 1 : 0.15, anchor: .leading)
            }
            .frame(height: 2)
        }
        .animation(reduceMotion ? nil : GroveMotion.snap, value: isFocused)
    }
}

/// A provider capsule on the account screen: filled with ink, or outlined.
struct OnboardingProviderButton: View {
    let title: String
    var systemImage: String?
    var assetImage: String?
    var filled: Bool = true
    var height: CGFloat = OnboardingTheme.controlHeight
    var cornerRadius: CGFloat = OnboardingTheme.controlRadius
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if filled {
                OnboardingInkCapsuleLabel(title: title)
            } else {
                OnboardingOutlineCapsuleLabel(
                    title: title,
                    systemImage: systemImage,
                    assetImage: assetImage
                )
            }
        }
        .buttonStyle(GrovePressStyle())
    }
}
