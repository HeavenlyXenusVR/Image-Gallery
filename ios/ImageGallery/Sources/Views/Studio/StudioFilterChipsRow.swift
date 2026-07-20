import SwiftUI

/// Pure view-layer filter — not a `StudioViewModel` property, since it only
/// narrows the already-loaded `items` locally rather than changing what's
/// fetched. Raw values match the backend's own visibility strings so
/// filtering is a direct `==` comparison, no separate label-mapping table.
enum StudioFilter: String, CaseIterable, Identifiable {
    case all
    case `public`
    case unlisted
    case `private`
    case deleted
    case scheduled

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .public: return "Public"
        case .unlisted: return "Unlisted"
        case .private: return "Private"
        case .deleted: return "Deleted"
        case .scheduled: return "Scheduled"
        }
    }
}

struct StudioFilterChipsRow: View {
    @Binding var selected: StudioFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(StudioFilter.allCases) { filter in
                    let isSelected = selected == filter
                    Button {
                        selected = filter
                    } label: {
                        Text(filter.label)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.12)), in: Capsule())
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
