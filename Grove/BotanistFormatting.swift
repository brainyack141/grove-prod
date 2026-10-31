import Foundation

/// Turns the coach's reply into something a bubble can actually draw.
///
/// The provider writes markdown whatever the system prompt asks of it — a
/// formatting instruction is a request, not a contract, and it drifts with every
/// model version. SwiftUI's `Text` takes a `String` verbatim, so before this
/// every `**` and `#` reached the user as literal punctuation.
///
/// So the model's syntax is treated as untrusted *shape*: normalise the block
/// constructs a chat bubble cannot draw, then let `AttributedString` handle the
/// inline emphasis. Nothing here can fail into an empty answer — a reply the
/// user paid a question for is never worth less than its raw text.
enum BotanistFormatting {

    /// Display form: emphasis applied, block syntax normalised away.
    static func attributed(_ raw: String) -> AttributedString {
        let lines = normalised(raw).components(separatedBy: "\n")
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            result.append(inline(line))
        }
        return result
    }

    /// Speech and preview form: the same words with every marker gone.
    ///
    /// VoiceOver reading "asterisk asterisk overwatering" is the same defect
    /// heard rather than seen, and the recents list previews an answer at two
    /// lines — markers there would spend both lines on punctuation.
    static func plain(_ raw: String) -> String {
        String(attributed(raw).characters)
    }

    // MARK: - Block syntax

    /// Strips what the bubble cannot draw and collapses the vertical padding a
    /// model leaves behind. Leading indentation goes with it: nested lists read
    /// worse than flat ones at bubble width.
    private static func normalised(_ raw: String) -> String {
        var lines: [String] = []
        var pendingBlank = false

        for original in raw.components(separatedBy: .newlines) {
            let trimmed = original.trimmingCharacters(in: .whitespaces)

            // Fences and horizontal rules carry no meaning once the block
            // structure they divide is gone.
            if trimmed.hasPrefix("```") { continue }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { continue }

            if trimmed.isEmpty {
                // One blank line is a paragraph break; a run of them is padding.
                // Leading blanks are dropped entirely.
                pendingBlank = !lines.isEmpty
                continue
            }

            let rewritten = rewrite(trimmed)
            guard !rewritten.isEmpty else { continue }
            if pendingBlank { lines.append("") }
            pendingBlank = false
            lines.append(rewritten)
        }
        return lines.joined(separator: "\n")
    }

    /// One line of block syntax, turned into something drawable.
    private static func rewrite(_ line: String) -> String {
        var line = line

        // A blockquote marker means nothing inside a bubble that is already
        // visibly a quotation from the botanist.
        while line.hasPrefix(">") {
            line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        // ATX headers. The system prompt forbids them; this is the belt to that
        // pair of braces, for the day a model version ignores it. Kept as bold
        // rather than dropped — a heading the model bothered to write is usually
        // the shape of the answer.
        if line.hasPrefix("#") {
            let text = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return "" }
            // Re-emphasising already-emphasised text nests the markers, and a
            // nested pair parses as literal asterisks — the exact bug this file
            // exists to stop.
            return text.contains("**") ? text : "**\(text)**"
        }

        // A real bullet glyph, so a list survives with no syntax left in it.
        // Ordered lists are left alone: "1." already reads as a step.
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return "•  " + closingDanglingBold(String(line.dropFirst(marker.count)))
        }
        return closingDanglingBold(line)
    }

    /// Closes a `**` the model opened and never closed.
    ///
    /// Markdown treats an unclosed marker as literal, which means the output
    /// ceiling we added to stop 400-word essays would itself put asterisks back
    /// on screen: a reply cut off mid-emphasis ends on a dangling `**`. Dropping
    /// the orphan is better than showing it — the emphasis was decoration, the
    /// sentence was the answer.
    ///
    /// Only `**` is balanced. A lone `*` is far more often arithmetic or a
    /// footnote than an unclosed italic, and the prompt asks for bold anyway.
    private static func closingDanglingBold(_ line: String) -> String {
        let parts = line.components(separatedBy: "**")
        // n markers produce n + 1 parts, so an odd marker count is an even one.
        guard parts.count % 2 == 0, let last = parts.last else { return line }
        return parts.dropLast().joined(separator: "**") + last
    }

    // MARK: - Inline syntax

    /// Inline-only: block constructs were handled above, and letting the parser
    /// see them again would re-introduce the list and heading collapsing that
    /// `normalised` just undid.
    private static let options = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: false,
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible
    )

    private static func inline(_ line: String) -> AttributedString {
        guard !line.isEmpty else { return AttributedString() }
        // A line that parses away to nothing — a stray marker standing alone —
        // would silently delete part of the answer, so keep the literal text.
        guard let parsed = try? AttributedString(markdown: line, options: options),
              !parsed.characters.isEmpty else {
            return AttributedString(line)
        }
        // The bubble contract is bold and italic only. `AttributedString` also
        // turns model-authored Markdown into live links, which would let a
        // hallucinated or compromised URL masquerade as trusted Grove UI.
        // Preserve the visible label, but remove every tap target.
        var safe = parsed
        let linkedRanges = safe.runs.compactMap { run in
            run.link == nil ? nil : run.range
        }
        for range in linkedRanges { safe[range].link = nil }
        return safe
    }
}
