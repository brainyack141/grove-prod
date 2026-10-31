import SwiftUI
import Vortex

// The Journey's particle effects, powered by the Vortex particle engine.
// Each view builds its own system instance so no state is shared between
// concurrent layers (Vortex presets are shared singletons — always copy).

// MARK: - Ambient world atmosphere

/// A living layer over the whole map: glowing fireflies at night and authored
/// botanical keepsakes tumbling through the daylight.
struct AmbientParticleLayer: View {
    let dark: Bool

    var body: some View {
        Group {
            if dark {
                VortexView(Self.fireflies()) {
                    Circle()
                        .fill(JourneyWorld.firefly)
                        .frame(width: 26, height: 26)
                        .blur(radius: 4)
                        .blendMode(.plusLighter)
                        .tag("firefly")
                }
            } else {
                VortexView(Self.meadowDrift()) {
                    particle("JourneyParticleOliveLeaf", size: 34)
                        .tag("olive-leaf")
                    particle("JourneyParticleGinkgoLeaf", size: 32)
                        .tag("ginkgo-leaf")
                    particle("JourneyParticleBlossomPetal", size: 30)
                        .tag("blossom-petal")
                    particle("JourneyParticleSamaraSeed", size: 34)
                        .tag("samara-seed")
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func fireflies() -> VortexSystem {
        let system = VortexSystem.fireflies.makeUniqueCopy()
        system.position = [0.5, 0.5]
        system.shape = .box(width: 1, height: 1)
        system.birthRate = 14
        return system
    }

    private func particle(_ asset: String, size: CGFloat) -> some View {
        Image(asset)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
    }

    /// Leaves, a petal and a winged seed falling gently from the top of the
    /// world. The slow spin and broad size range keep repeated sprites from
    /// looking stamped onto the map.
    private static func meadowDrift() -> VortexSystem {
        VortexSystem(
            tags: ["olive-leaf", "ginkgo-leaf", "blossom-petal", "samara-seed"],
            position: [0.5, 0],
            shape: .box(width: 1, height: 0),
            birthRate: 2.4,
            lifespan: 13,
            speed: 0.055,
            speedVariation: 0.035,
            angle: .degrees(180),
            angleRange: .degrees(24),
            angularSpeedVariation: [1.2, 1.8, 2.4],
            size: 0.82,
            sizeVariation: 0.32
        )
    }
}

// MARK: - Celebration confetti

/// A physics-y confetti storm: three staggered bursts from above centre.
struct ConfettiBurstView: View {
    var body: some View {
        VortexViewReader { proxy in
            VortexView(Self.system()) {
                Rectangle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .tag("square")
                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .tag("circle")
            }
            .task {
                proxy.burst()
                for _ in 0..<2 {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    proxy.burst()
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func system() -> VortexSystem {
        let system = VortexSystem.confetti.makeUniqueCopy()
        system.position = [0.5, 0.25]
        return system
    }
}
