import Foundation

/// The decisions behind the remote `file_read` and `file_edit` tools, so `RemoteFileService` slices, matches
/// and words its results like the app's local tools. Ported from `AIChatViewModel+FileTools.swift` and
/// `FileToolIO.swift` (`executeFileRead`, `executeFileEdit`, `applyEdit` and their helpers), which stay upstream's own;
/// `FileToolDriftTests` fails when upstream changes those functions, so the change gets ported here.
/// Callers handle path resolution, existence checks and the app-only `minis_url:` suffix.
public enum FileToolLogic {
    /// T-FILEREAD-CAP: the Android FileReadTool cap, so both platforms refuse the same oversized reads.
    public static let readMaxLengthCap = 80_000

    /// A NUL byte this early marks a file as binary.
    public static let binarySniffLength = 512

    public enum ReadOutcome: Equatable, Sendable {
        case text(String)
        /// The app returns this as a successful result.
        case binary(String)
        case rejected(String)
    }

    public enum EditOutcome: Equatable, Sendable {
        case edited(updatedContent: String, summary: String)
        case rejected(String)
    }

    public static func readMissingFileMessage(path: String) -> String {
        "Error: No such file: \(path)"
    }

    public static func editMissingFileMessage(path: String) -> String {
        "Error: File does not exist: \(path). Use file_write to create new files."
    }

    /// Needs only the first `binarySniffLength` bytes, so a remote caller can decide before downloading the rest.
    public static func binaryPreview(path: String, leadingBytes: Data, totalBytes: Int) -> String? {
        guard leadingBytes.prefix(binarySniffLength).contains(0) else { return nil }
        let hexPreview = leadingBytes.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
        return "[\(path) | \(totalBytes) bytes | binary file]\nHex preview: \(hexPreview)"
    }

    /// Upstream's local file_read traps on these; a model-supplied value must never crash the app on a remote read.
    public static func readParameterError(lines: Int?, maxLength: Int?) -> String? {
        if let lines, lines < 1 { return "Error: lines must be a positive integer" }
        if let maxLength, maxLength < 1 { return "Error: max_length must be a positive integer" }
        return nil
    }

    public static func read(
        path: String, data: Data, offset: Int?, lines: Int?, direction: String?, maxLength: Int?,
        defaultMaxLength: Int
    ) -> ReadOutcome {
        if let parameterError = readParameterError(lines: lines, maxLength: maxLength) {
            return .rejected(parameterError)
        }
        if let preview = binaryPreview(path: path, leadingBytes: data, totalBytes: data.count) {
            return .binary(preview)
        }
        guard let fullText = String(data: data, encoding: .utf8) else {
            return .rejected("Error: \(path) is not valid UTF-8 text")
        }

        let startOffset = max(1, offset ?? 1)
        let effectiveMaxLength = min(maxLength ?? defaultMaxLength, readMaxLengthCap)
        let isTail = (direction?.lowercased() ?? "head") == "tail"

        let allLines = fullText.components(separatedBy: "\n")
        let totalLines = allLines.count
        let selectedLines: ArraySlice<String>
        let displayStart: Int
        let displayEnd: Int
        if isTail {
            let sliced = allLines.suffix(lines ?? allLines.count)
            selectedLines = sliced
            displayStart = allLines.count - sliced.count + 1
            displayEnd = allLines.count
        } else {
            let startIdx = min(startOffset - 1, allLines.count)
            let endIdx = startIdx + min(lines ?? allLines.count, allLines.count - startIdx)
            selectedLines = allLines[startIdx..<endIdx]
            displayStart = startIdx + 1
            displayEnd = endIdx
        }
        var content = selectedLines.joined(separator: "\n")

        // [T-fileread-truncation-header] A truncated read reports the lines that actually survived and the
        // offset to resume from; reporting the pre-truncation range made the agent think it had the whole file.
        var wasTruncated = false
        var effectiveStart = displayStart
        var effectiveEnd = displayEnd
        var nextOffset: Int?
        if content.count > effectiveMaxLength {
            wasTruncated = true
            if isTail {
                content = String(content.suffix(effectiveMaxLength))
                if let firstNewline = content.firstIndex(of: "\n"),
                   content.distance(from: content.startIndex, to: firstNewline) < content.count - 1 {
                    content = String(content[content.index(after: firstNewline)...])
                }
                effectiveStart = displayEnd - content.components(separatedBy: "\n").count + 1
                // No next_offset for tail: paging forward from the end of the file is meaningless.
            } else {
                content = String(content.prefix(effectiveMaxLength))
                // A half-line would be duplicated or stitched onto the next page.
                if let lastNewline = content.lastIndex(of: "\n") {
                    content = String(content[content.startIndex..<lastNewline])
                }
                effectiveEnd = displayStart + content.components(separatedBy: "\n").count - 1
                if effectiveEnd < totalLines { nextOffset = effectiveEnd + 1 }
            }
        }

        let rangeInfo = "showing lines \(effectiveStart)-\(effectiveEnd) of \(totalLines)"
        var header = "[\(path) | \(data.count) bytes | \(totalLines) lines | \(rangeInfo)"
        if wasTruncated {
            header += " | truncated at \(effectiveMaxLength) chars"
            if let nextOffset {
                // Named like the tool's `offset` parameter so the model can copy it into the next call.
                header += ", next_offset=\(nextOffset)"
            } else {
                header += ", retry with a smaller lines value"
            }
        }
        header += "]"
        return .text("\(header)\n\(content)")
    }

    public static func edit(
        path: String, data: Data, oldString: String, newString: String, replaceAll: Bool
    ) -> EditOutcome {
        guard let fileContent = String(data: data, encoding: .utf8) else {
            return .rejected("Error: Could not read \(path) as UTF-8 text")
        }
        guard !oldString.isEmpty else {
            return .rejected("Error: old_string must not be empty. Use file_write to create or overwrite files.")
        }

        let editRanges: [Range<String.Index>]
        let fuzzyNote: String?
        let strictRanges = findAllRanges(of: oldString, in: fileContent)
        if !strictRanges.isEmpty {
            editRanges = strictRanges
            fuzzyNote = nil
        } else {
            // Models re-emit smart quotes as ASCII and drop trailing or repeated spaces. Match on normalized
            // text but replace the original byte ranges, and say so, so the model learns it was not verbatim.
            let (normFile, fileMap) = normalizeForFuzzyMatch(fileContent)
            let (normOld, _) = normalizeForFuzzyMatch(oldString)
            let normRanges = findAllRanges(of: normOld, in: normFile)
            if normRanges.isEmpty {
                let preview = buildFileEditPreview(fileContent: fileContent, normFile: normFile, normOld: normOld)
                return .rejected(
                    "Error: old_string not found in \(path). Use file_read to view current file contents before editing.\n\n\(preview)")
            }
            editRanges = mapToOriginal(normRanges, normFile: normFile, fileMap: fileMap, fileContent: fileContent)
            fuzzyNote = "fuzzy-matched: quotes/whitespace normalized"
        }

        if editRanges.count > 1 && !replaceAll {
            return .rejected(
                "Error: old_string matches \(editRanges.count) locations in \(path). Provide more surrounding context to make the match unique, or set replace_all: true to replace all occurrences.")
        }

        var updatedContent = fileContent
        for range in editRanges.reversed() {
            updatedContent.replaceSubrange(range, with: newString)
        }

        let replacements = editRanges.count == 1 ? "1 replacement" : "\(editRanges.count) replacements"
        var summary = "Edited \(path) (\(replacements), \(updatedContent.utf8.count) bytes)"
        if let fuzzyNote {
            summary += " — \(fuzzyNote)"
        }
        return .edited(updatedContent: updatedContent, summary: summary)
    }

    /// Non-overlapping, ascending.
    static func findAllRanges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var results: [Range<String.Index>] = []
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let r = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            results.append(r)
            searchStart = r.upperBound
        }
        return results
    }

    /// Works on Characters on both sides, so multi-byte UTF-8 maps back correctly.
    private static func mapToOriginal(
        _ normRanges: [Range<String.Index>], normFile: String, fileMap: [String.Index], fileContent: String
    ) -> [Range<String.Index>] {
        var mapped: [Range<String.Index>] = []
        mapped.reserveCapacity(normRanges.count)
        for r in normRanges {
            let startOffset = normFile.distance(from: normFile.startIndex, to: r.lowerBound)
            let endOffset = normFile.distance(from: normFile.startIndex, to: r.upperBound)
            guard startOffset < fileMap.count else { continue }
            let originalStart = fileMap[startOffset]
            let originalEnd: String.Index
            if endOffset == 0 {
                originalEnd = fileContent.startIndex
            } else if endOffset <= fileMap.count {
                originalEnd = fileContent.index(after: fileMap[endOffset - 1])
            } else {
                originalEnd = fileContent.endIndex
            }
            mapped.append(originalStart..<originalEnd)
        }
        return mapped
    }

    /// Returns the normalized text and, per normalized Character, its index in the original.
    /// Smart quotes become ASCII, trailing spaces are dropped and inline space runs collapse to one; leading
    /// indent, tabs and other whitespace stay so indentation-significant files still match strictly.
    static func normalizeForFuzzyMatch(_ text: String) -> (String, [String.Index]) {
        var out = String()
        out.reserveCapacity(text.count)
        var map: [String.Index] = []
        map.reserveCapacity(text.count)

        let chars = Array(text)
        let indices = Array(text.indices)
        var i = 0
        var atLineStart = true
        while i < chars.count {
            let ch = chars[i]
            if ch == "\n" {
                out.append(ch); map.append(indices[i])
                atLineStart = true
                i += 1
                continue
            }
            var emit: Character = ch
            switch ch {
            case "\u{201C}", "\u{201D}": emit = "\""
            case "\u{2018}", "\u{2019}": emit = "'"
            default: break
            }
            if ch == " " {
                var j = i
                while j < chars.count, chars[j] == " " { j += 1 }
                let isTrailing = (j == chars.count) || (chars[j] == "\n")
                if isTrailing {
                    i = j
                    continue
                }
                if atLineStart {
                    for k in i..<j {
                        out.append(" "); map.append(indices[k])
                    }
                    i = j
                    atLineStart = false
                    continue
                }
                out.append(" "); map.append(indices[i])
                i = j
                continue
            }
            out.append(emit); map.append(indices[i])
            atLineStart = false
            i += 1
        }
        return (out, map)
    }

    /// Anchors on the first 60 normalized characters of old_string, because failed matches usually differ
    /// later in the string; shows ±10 lines around it, or the file head when there is no anchor.
    private static func buildFileEditPreview(fileContent: String, normFile: String, normOld: String) -> String {
        let probeLen = min(60, normOld.count)
        let probeEnd = normOld.index(normOld.startIndex, offsetBy: probeLen)
        let probe = String(normOld[..<probeEnd])
        var anchorLine: Int?
        if !probe.isEmpty, let r = normFile.range(of: probe) {
            // Normalization never adds or removes "\n", so line numbers carry over to the original.
            anchorLine = normFile[normFile.startIndex..<r.lowerBound].filter { $0 == "\n" }.count
        }
        let lines = fileContent.components(separatedBy: "\n")
        if let a = anchorLine {
            let start = max(0, a - 10)
            let end = min(lines.count, a + 11)
            var out = "Closest match in file (lines \(start + 1)–\(end), normalized old_string anchor at line \(a + 1)):\n"
            out += lines[start..<end].enumerated()
                .map { "\(start + $0.offset + 1): \($0.element)" }
                .joined(separator: "\n")
            out += "\n\nNote: file may use smart quotes (\u{201C}\u{201D}\u{2018}\u{2019}), tabs, or trailing whitespace your old_string omits. Re-read the file and copy the exact bytes."
            return out
        }
        let preview = lines.prefix(20).enumerated().map { "\($0.offset + 1): \($0.element)" }.joined(separator: "\n")
        return "First 20 lines:\n\(preview)"
    }
}
