import Foundation

#if canImport(Darwin)
import Darwin

private let globFunction = Darwin.glob
#elseif canImport(Glibc)
import Glibc

private let globFunction = Glibc.glob
#else
#error("Unsupported platform")
#endif

// Adapted from https://gist.github.com/efirestone/ce01ae109e08772647eb061b3bb387c3

struct Glob {
	// adapted from https://github.com/fitzgen/glob-to-regexp/blob/master/index.js
	static func convertGlob(_ pattern: String) throws -> NSRegularExpression {
		// The regexp we are building, as a string.
		var regexPattern = ""

		// this boolean is true when we are inside a group (eg {*.html,*.js}), and false otherwise.
		var inGroup = false

		var index = pattern.startIndex
		while index < pattern.endIndex {
			let character = pattern[index]

			switch character {
			case "/", "$", "^", "+", ".", "(", ")", "=", "!", "|":
				regexPattern += "\\" + String(character)
			case "?":
				regexPattern += "."
			case "[", "]":
				regexPattern.append(character)
			case "{":
				inGroup = true
				regexPattern.append("(")
			case "}":
				inGroup = false
				regexPattern += ")"
			case ",":
				if inGroup {
					regexPattern.append("|")
				} else {
					regexPattern += "\\" + String(character)
				}
			case "*":
				// Move over all consecutive "*"'s.
				// Also store the previous and next characters
				let prevChar = pattern.prefix(upTo: index).last

				let starRange = pattern
					.suffix(from: index)
					.prefix(while: { $0 == "*" })
				let starCount = starRange.count
				index = starRange.endIndex
				let nextChar = pattern.suffix(from: index).first

				let isGlobstar = starCount > 1 // multiple "*"'s
				&& (prevChar == "/" || prevChar == nil) // from the start of the segment
				&& (nextChar == "/" || nextChar == nil) // to the end of the segment

				if isGlobstar {
					// it's a globstar, so match zero or more path segments
					regexPattern += "((?:[^/]*(?:/|$))*)"
					index = pattern.index(after: index) // move over the "/"
				} else {
					// it's not a globstar, so only match one path segment
					regexPattern += "([^/]*)"
				}
                
                continue // skip index++]
			default:
				regexPattern.append(character)
			}

			index = pattern.index(after: index)
		}

		regexPattern = "^" + regexPattern

		return try NSRegularExpression(pattern: regexPattern)
	}

    static func resolveGlob(_ pattern: String) -> [String] {
        let globCharset = CharacterSet(charactersIn: "*?[]")
        guard pattern.rangeOfCharacter(from: globCharset) != nil else {
            return [pattern]
        }

        return expandGlobstar(pattern: pattern)
            .reduce(into: [String]()) { paths, pattern in
                var globResult = glob_t()
                defer { globfree(&globResult) }

                if globFunction(pattern, GLOB_TILDE | GLOB_BRACE | GLOB_MARK, nil, &globResult) == 0 {
                    paths.append(contentsOf: populateFiles(globResult: globResult))
                }
            }
            .unique
            .sorted()
            .map { $0.absolutePathStandardized() }
    }

    // MARK: Private

    private static func expandGlobstar(pattern: String) -> [String] {
        guard pattern.contains("**") else {
            return [pattern]
        }
        var parts = pattern.components(separatedBy: "**")
        let firstPart = parts.removeFirst()
        let fileManager = FileManager.default
        guard firstPart.isEmpty || fileManager.fileExists(atPath: firstPart) else {
            return []
        }
        let searchPath = firstPart.isEmpty ? fileManager.currentDirectoryPath : firstPart
        var directories = [String]()
        do {
            directories = try fileManager.subpathsOfDirectory(atPath: searchPath).compactMap { subpath in
                let fullPath = firstPart.bridge().appendingPathComponent(subpath)
                guard isDirectory(path: fullPath) else { return nil }
                return fullPath
            }
        } catch {
            Issue.genericWarning("Error parsing file system item: \(error)").print()
        }

        // Check the base directory for the glob star as well.
        directories.insert(firstPart, at: 0)

        var lastPart = parts.joined(separator: "**")
        var results = [String]()

        // Include the globstar root directory ("dir/") in a pattern like "dir/**" or "dir/**/"
        if lastPart.isEmpty {
            results.append(firstPart)
            lastPart = "*"
        }

        for directory in directories {
            let partiallyResolvedPattern: String
            if directory.isEmpty {
                partiallyResolvedPattern = lastPart.starts(with: "/") ? String(lastPart.dropFirst()) : lastPart
            } else {
                partiallyResolvedPattern = directory.bridge().appendingPathComponent(lastPart)
            }
            results.append(contentsOf: expandGlobstar(pattern: partiallyResolvedPattern))
        }

        return results
    }

    private static func isDirectory(path: String) -> Bool {
        var isDirectoryBool = ObjCBool(false)
        let isDirectory = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectoryBool)
        return isDirectory && isDirectoryBool.boolValue
    }

    private static func populateFiles(globResult: glob_t) -> [String] {
#if os(Linux)
        let matchCount = globResult.gl_pathc
#else
        let matchCount = globResult.gl_matchc
#endif
        return (0..<Int(matchCount)).compactMap { index in
            globResult.gl_pathv[index].flatMap { String(validatingUTF8: $0) }
        }
    }
}

extension NSRegularExpression {
    func hasMatch(in string: String) -> Bool {
        self.firstMatch(in: string, range: NSRange(location: 0, length: string.utf16.count)) != nil
    }
}
