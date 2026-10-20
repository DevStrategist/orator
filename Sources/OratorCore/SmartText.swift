import Foundation

/// Fits a sentence-cased transcript into the text around the insertion point, locally and deterministically.
public enum SmartText {
    static let pronouns: Set<String> = ["I", "I'm", "I've", "I'll", "I'd", "I’m", "I’ve", "I’ll", "I’d"]

    public static func adapt(_ text: String, before: String, after: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return text }
        let previous = before.last
        let next = after.first
        let midSentence = previous.map { !isSentenceBoundary(before) && !$0.isNewline } ?? false
        if midSentence, let first = result.first, first.isUppercase, !keepsCapital(result) {
            result = first.lowercased() + result.dropFirst()
        }
        if let next, next.isLetter || next.isNumber {
            // Inserting before existing words: the sentence continues, so drop the closing period.
            if result.hasSuffix("."), !result.hasSuffix("..") { result.removeLast() }
            result += " "
        }
        if let previous, !previous.isWhitespace, !opensGroup(previous),
           let first = result.first, first.isLetter || first.isNumber || opensGroup(first) {
            result = " " + result
        }
        return result
    }

    static func isSentenceBoundary(_ before: String) -> Bool {
        guard let last = before.trimmingCharacters(in: .whitespaces).last else { return true }
        return ".!?\n:".contains(last) || last == "…"
    }
    static func opensGroup(_ character: Character) -> Bool { "([{\"'“‘/@#-".contains(character) }
    static func keepsCapital(_ text: String) -> Bool {
        let word = String(text.prefix { $0.isLetter || $0 == "'" || $0 == "’" })
        if pronouns.contains(word) { return true }
        // Acronyms and camel-cased names carry meaning in their other capitals.
        return word.dropFirst().contains { $0.isUppercase }
    }
}
