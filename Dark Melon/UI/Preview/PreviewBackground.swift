import SwiftUI

enum PreviewBackground: String, CaseIterable {
    case darkGrey, grey, lightGrey, glass

    static let preferenceKey = "preview.background"

    static func resolve(_ stored: String, glassEffects: Bool) -> Self {
        // Preserve background choices saved under the previous names.
        switch stored {
        case "black": return .darkGrey
        case "white": return .lightGrey
        case "smoke": return .glass
        default: return Self(rawValue: stored) ?? (glassEffects ? .glass : .darkGrey)
        }
    }

    var greyLevel: Double? {
        switch self {
        case .darkGrey: 0.06
        case .grey: 0.18
        case .lightGrey: 0.90
        case .glass: nil
        }
    }

    var title: String {
        switch self {
        case .darkGrey: String(localized: "Black")
        case .grey: String(localized: "Grey")
        case .lightGrey: String(localized: "White")
        case .glass: String(localized: "Glass")
        }
    }
}

/// Native image views provide their own hit-tested menu; empty previews use this one.
struct EmptyPreviewBackgroundMenu: ViewModifier {
    let enabled: Bool
    @AppStorage(PreviewBackground.preferenceKey) private var choice = ""
    @AppStorage("glassEffectsEnabled") private var glassEffects = true

    func body(content: Content) -> some View {
        if enabled {
            content.contentShape(Rectangle()).contextMenu {
                ForEach(PreviewBackground.allCases, id: \.self) { background in
                    Button {
                        choice = background.rawValue
                    } label: {
                        if PreviewBackground.resolve(choice, glassEffects: glassEffects) == background {
                            Label(background.title, systemImage: "checkmark")
                        } else {
                            Text(background.title)
                        }
                    }
                }
            }
        } else {
            content
        }
    }
}
