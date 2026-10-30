import SwiftUI
import AppKit

/// Cards picked for an action, the Finder way: a click selects one,
/// ⌘-click adds or removes, ⇧-click takes the range from the last click.
struct CardSelection: Equatable {
    private(set) var ids: Set<String> = []
    /// The last plain or ⌘ click, where a ⇧-click range starts.
    private var anchor: String?

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }
    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// `order`: the cards' ids as they're laid out, for ranges.
    mutating func click(_ id: String, in order: [String], modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let anchor, let from = order.firstIndex(of: anchor),
           let to = order.firstIndex(of: id) {
            ids.formUnion(order[min(from, to)...max(from, to)])
        } else if modifiers.contains(.command) {
            if ids.remove(id) == nil { ids.insert(id) }
            anchor = id
        } else {
            ids = [id]
            anchor = id
        }
    }

    mutating func toggle(_ id: String) {
        if ids.remove(id) == nil { ids.insert(id) }
        anchor = id
    }

    mutating func select(_ all: [String]) { ids = Set(all) }
    mutating func set(_ new: Set<String>) { ids = new }
    mutating func clear() { ids = []; anchor = nil }

    /// Forget cards that are gone.
    mutating func keep(_ existing: Set<String>) {
        ids.formIntersection(existing)
        if let anchor, !existing.contains(anchor) { self.anchor = nil }
    }
}

extension View {
    /// A card that can be selected: click selects (⌘ and ⇧ as in Finder),
    /// double-click or Return opens, Space adds or removes it. Selected, it
    /// takes an accent edge and tint; focused from the keyboard, a fainter edge.
    func selectableCard(_ id: String, in selection: Binding<CardSelection>, order: [String],
                        cornerRadius: CGFloat, open: (() -> Void)? = nil) -> some View {
        modifier(SelectableCard(id: id, selection: selection, order: order, cornerRadius: cornerRadius, open: open))
    }
}

private struct SelectableCard: ViewModifier {
    let id: String
    @Binding var selection: CardSelection
    let order: [String]
    let cornerRadius: CGFloat
    let open: (() -> Void)?
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        let selected = selection.contains(id)
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        content
            .overlay(shape.fill(DS.accent.opacity(selected ? 0.07 : 0)).allowsHitTesting(false))
            .overlay(shape.strokeBorder(DS.accent.opacity(selected ? 1 : focused ? 0.5 : 0), lineWidth: 2)
                .allowsHitTesting(false))
            .contentShape(shape)
            .onTapGesture(count: 2) { open?() }
            .simultaneousGesture(TapGesture().onEnded {
                selection.click(id, in: order, modifiers: NSEvent.modifierFlags)
                focused = true
            })
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.return) {
                guard let open else { return .ignored }
                open()
                return .handled
            }
            .onKeyPress(.space) { selection.toggle(id); return .handled }
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityAction { if let open { open() } else { selection.toggle(id) } }
            .accessibilityAction(named: selected ? Text("Deselect") : Text("Select")) { selection.toggle(id) }
    }
}

/// A scroll view of selectable cards: a click on empty space, or Escape,
/// clears the selection; ⌘A selects every card; Delete asks to delete the
/// selected ones.
struct SelectionScroll<Content: View>: View {
    @Binding var selection: CardSelection
    /// Every selectable card, in order.
    let all: [String]
    var onDelete: (() -> Void)?
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                // As tall as the view, so the space below the cards takes clicks too.
                .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
                // Behind the cards: only a click on empty space reaches it.
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { selection.clear() }
                }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .onCommand(#selector(NSResponder.selectAll(_:))) { selection.select(all) }
        .onExitCommand { selection.clear() }
        .onDeleteCommand { if !selection.isEmpty { onDelete?() } }
        .onChange(of: all) { _, ids in selection.keep(Set(ids)) }
    }
}

/// What to do with the selected cards: floats at the bottom while any are
/// selected. `actions` are plain buttons; Deselect comes last.
struct SelectionBar<Actions: View>: View {
    let count: Int
    let onClear: () -> Void
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: DS.Spacing.m) {
            Text("\(count) selected")
                .font(.callout.weight(.medium))
                .monospacedDigit()
            HStack(spacing: DS.Spacing.s) { actions }
            Button(action: onClear) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Deselect (Esc)")
            .accessibilityLabel("Deselect")
        }
        .controlSize(.regular)
        .floatingPanel()
        .padding(DS.Spacing.l)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("selectionBar")
    }
}
