import Foundation

/// How a rule's phrases are compared with what was said. Phrases always match whole words, in order, after
/// normalisation (case, punctuation, number words); `contains` also matches inside words.
public enum MatchMode: String, CaseIterable {
    /// Whole words. Words of 8+ letters may differ by one letter ("favourite" matches "favorite"); shorter
    /// words must match exactly, since "missing" vs "kissing" is too close to tolerate.
    case words
    /// Whole words, more forgiving: 4+ letters may differ by one, 7+ letters by two ("yoda" matches "yuda").
    case fuzzy
    /// Anywhere in the text, including inside longer words ("epic" matches "epically").
    case contains
}

private let numberUnits: [String: Int] = [
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
    "seventeen": 17, "eighteen": 18, "nineteen": 19
]
private let numberTens: [String: Int] = [
    "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
]

/// Lowercases, removes punctuation and symbols, and writes number words below 100 as digits, so that
/// "Fifteen!", "£15" and "15" all become "15" and "twenty-one" becomes "21". The model writes most numbers as
/// digits; this lets rules use either.
public func normalizeText(_ text: String) -> String {
    var cleaned = ""
    cleaned.reserveCapacity(text.count)
    var lastWasSpace = true
    for scalar in text.lowercased().unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) {
            cleaned.unicodeScalars.append(scalar)
            lastWasSpace = false
        } else if !lastWasSpace {
            cleaned.append(" ")
            lastWasSpace = true
        }
    }

    let words = cleaned.split(separator: " ").map(String.init)
    var out: [String] = []
    var i = 0
    while i < words.count {
        if let tens = numberTens[words[i]] {
            if i + 1 < words.count, let unit = numberUnits[words[i + 1]], unit > 0, unit < 10 {
                out.append(String(tens + unit))
                i += 2
                continue
            }
            out.append(String(tens))
        } else if let unit = numberUnits[words[i]] {
            out.append(String(unit))
        } else {
            out.append(words[i])
        }
        i += 1
    }
    return out.joined(separator: " ")
}

public func tokenize(_ normalized: String) -> [String] {
    normalized.split(separator: " ").map(String.init)
}

public func withinEditDistance(_ a: String, _ b: String, maxDistance: Int) -> Bool {
    if maxDistance <= 0 { return a == b }
    if a == b { return true }
    let aChars = Array(a.utf16)
    let bChars = Array(b.utf16)
    let n = aChars.count
    let m = bChars.count
    if abs(n - m) > maxDistance { return false }
    if n == 0 { return m <= maxDistance }
    if m == 0 { return n <= maxDistance }

    var prev = Array(0...m)
    var curr = Array(repeating: 0, count: m + 1)

    for i in 1...n {
        curr[0] = i
        var rowMin = curr[0]
        let aCh = aChars[i - 1]
        for j in 1...m {
            let cost = aCh == bChars[j - 1] ? 0 : 1
            let v = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            curr[j] = v
            if v < rowMin { rowMin = v }
        }
        if rowMin > maxDistance { return false }
        swap(&prev, &curr)
    }

    return prev[m] <= maxDistance
}

/// Whether a spoken word counts as a phrase word under `mode` (both already normalised).
func wordsMatch(_ spoken: String, _ expected: String, mode: MatchMode) -> Bool {
    if spoken == expected { return true }
    let shorter = min(spoken.count, expected.count)
    switch mode {
    case .words:
        return shorter >= 8 && withinEditDistance(spoken, expected, maxDistance: 1)
    case .fuzzy:
        if shorter >= 7 { return withinEditDistance(spoken, expected, maxDistance: 2) }
        return shorter >= 4 && withinEditDistance(spoken, expected, maxDistance: 1)
    case .contains:
        return false
    }
}

/// A phrase prepared for matching.
struct Phrase: Equatable {
    let text: String
    let normalized: String
    let tokens: [String]

    init(_ text: String) {
        self.text = text
        self.normalized = normalizeText(text)
        self.tokens = tokenize(normalized)
    }

    /// Index of the first spoken word where this phrase starts, or nil.
    func firstMatch(in spoken: [String], normalized spokenText: String, mode: MatchMode) -> Int? {
        guard !tokens.isEmpty else { return nil }
        if mode == .contains {
            guard let range = spokenText.range(of: normalized) else { return nil }
            return spokenText[..<range.lowerBound].split(separator: " ").count
        }
        guard tokens.count <= spoken.count else { return nil }
        for start in 0...(spoken.count - tokens.count) {
            let matched = zip(spoken[start...], tokens).allSatisfy { wordsMatch($0, $1, mode: mode) }
            if matched { return start }
        }
        return nil
    }
}
