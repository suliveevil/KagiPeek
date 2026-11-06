import Foundation

/// Parses a typed number for a settings field.
///
/// The fields are plain integers with a fixed range, so there is no formatter to keep in
/// sync with the UI: anything that is not a bare whole number inside the range is rejected
/// and the caller keeps the value it already had. Full-width digits are folded first,
/// because a Chinese input method can produce `２４` while the keyboard is in pinyin mode.
nonisolated enum NumericSettingInput {
    static func value(from draft: String, in range: ClosedRange<Int>) -> Int? {
        let halfWidth = draft.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? draft
        let trimmed = halfWidth.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
              let parsed = Int(trimmed),
              range.contains(parsed)
        else { return nil }

        return parsed
    }
}
