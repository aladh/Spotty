/// View identity belongs to an occurrence, while navigation keeps the original catalog value.
/// Ordinals are local to each source ID, so inserting unrelated entries preserves existing state.
/// Indistinguishable repeats have no server occurrence key; their relative order identifies them.
struct CatalogDisplayOccurrence<Element: Identifiable>: Identifiable {
    struct ID: Hashable {
        let source: Element.ID
        let ordinal: Int
    }

    let id: ID
    let index: Int
    let element: Element

    static func identifying(_ elements: [Element]) -> [Self] {
        var ordinals: [Element.ID: Int] = [:]
        return elements.enumerated().map { index, element in
            let ordinal = ordinals[element.id, default: 0]
            ordinals[element.id] = ordinal + 1
            return Self(id: ID(source: element.id, ordinal: ordinal), index: index, element: element)
        }
    }
}
