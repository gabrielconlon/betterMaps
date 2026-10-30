import SwiftUI

/// Always-visible top of the sheet: the search field, the "+" menu and the
/// Settings gear (Cancel replaces both while searching). Nothing else, so
/// the collapsed sheet is one row; what the map shows is chosen in the
/// layers panel. The gear shows at every detent: hidden while collapsed, it
/// was easy to never see at all, and Settings now holds tag and trail-group
/// management as well as the directions options.
struct LayersSheetHeader: View {
    @Bindable var searchState: SearchState
    var isSearchFocused: FocusState<Bool>.Binding
    let onSearchTextChanged: () -> Void
    let onCancelSearch: () -> Void
    let onAddPlace: () -> Void
    /// Opens the trail editor; MapScreen picks or creates the trail layer.
    let onDrawTrail: () -> Void
    let onNewTag: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search places, stops, routes", text: $searchState.searchText)
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .focused(isSearchFocused)
                    .onChange(of: searchState.searchText) { _, _ in onSearchTextChanged() }
                    .onSubmit { isSearchFocused.wrappedValue = false }
                if !searchState.searchText.isEmpty {
                    Button {
                        searchState.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))

            if isSearchFocused.wrappedValue || !searchState.searchText.isEmpty {
                Button("Cancel", action: onCancelSearch)
                    .font(.body)
                    .frame(minHeight: 44)
            } else {
                addMenu
                circleButton(systemImage: "gearshape", label: "Settings", action: onOpenSettings)
            }
        }
        .padding(.horizontal, 16)
    }

    private var addMenu: some View {
        Menu {
            Button(action: onAddPlace) { Label("Add place here", systemImage: "mappin.and.ellipse") }
            Button(action: onDrawTrail) { Label("Draw trail", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
            Button(action: onNewTag) { Label("New tag", systemImage: "tag") }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.accentColor, in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel("Add")
    }

    private func circleButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(Color(.tertiarySystemFill), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
