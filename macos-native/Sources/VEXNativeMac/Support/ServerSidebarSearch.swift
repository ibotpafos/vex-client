import Foundation

enum ServerSidebarSearch {
    static func matches(query: String, values: [String]) -> Bool {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else { return true }
        let queryVariants = Set([
            normalizedQuery,
            normalized(transliterated(query))
        ])
        return values.contains { value in
            let valueVariants = [
                normalized(value),
                normalized(transliterated(value))
            ]
            return queryVariants.contains { queryVariant in
                valueVariants.contains { $0.contains(queryVariant) }
            }
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func transliterated(_ value: String) -> String {
        value.applyingTransform(.toLatin, reverse: false) ?? value
    }
}
