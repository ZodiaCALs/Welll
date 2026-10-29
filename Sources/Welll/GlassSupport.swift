import SwiftUI

// Liquid Glass needs the macOS 26 SDK, which ships with Swift 6.2. Older toolchains and
// older versions of macOS get translucent materials instead, so the app builds and runs
// everywhere it did before.

extension View {
    /// A Liquid Glass surface in `shape`, optionally tinted to show state.
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint), in: shape)
            } else {
                self.glassEffect(.regular, in: shape)
            }
        } else {
            materialSurface(in: shape, tint: tint)
        }
        #else
        materialSurface(in: shape, tint: tint)
        #endif
    }

    /// The pre-Tahoe stand-in: a thin material with a hairline edge.
    func materialSurface<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        self
            .background { shape.fill(tint?.opacity(0.28) ?? Color.clear) }
            .background { shape.fill(.ultraThinMaterial) }
            .overlay { shape.stroke(Color.primary.opacity(0.1), lineWidth: 0.5) }
    }

    /// Glass buttons on macOS 26 and later, bordered buttons before.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            borderedButton(prominent: prominent)
        }
        #else
        borderedButton(prominent: prominent)
        #endif
    }

    @ViewBuilder
    func borderedButton(prominent: Bool) -> some View {
        if prominent {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

/// Lets neighbouring glass shapes render together and blend (GlassEffectContainer).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}
