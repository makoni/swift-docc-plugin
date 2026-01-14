// This source file is part of the Swift.org open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for Swift project authors

import Foundation

public enum GitBookExportError: LocalizedError {
    case missingDataDirectory(URL)
    case invalidArguments(String)

    public var errorDescription: String? {
        switch self {
        case .missingDataDirectory(let archiveURL):
            return "DocC archive at '\(archiveURL.path)' is missing a 'data' directory."
        case .invalidArguments(let message):
            return message
        }
    }
}

public struct GitBookExporter {
    public struct Page: Hashable {
        public enum Kind: String {
            case documentation
            case tutorials
            case articles
            case other
        }

        public var kind: Kind
        public var docURL: String
        public var title: String
        public var pathComponents: [String]
        public var relativeMarkdownPath: String
        public var sourceJSON: URL
    }

    public static func export(
        inputArchive: URL,
        outputDirectory: URL,
        bookTitle: String?
    ) throws {
        let fileManager = FileManager.default

        let dataDirectory = inputArchive.appendingPathComponent("data", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dataDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GitBookExportError.missingDataDirectory(inputArchive)
        }

        // Clean output dir
        try? fileManager.removeItem(at: outputDirectory)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let assetsDirectory = outputDirectory.appendingPathComponent("assets", isDirectory: true)
        try? fileManager.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)

        // Pass 1: discover pages + build docURL -> markdown path mapping.
        let pages = try discoverPages(in: dataDirectory)
        let docURLToMarkdownPath = Dictionary(uniqueKeysWithValues: pages.map { ($0.docURL, $0.relativeMarkdownPath) })

        // Pick a landing page for README.
        let landingPage = pages
            .filter { $0.kind == .documentation }
            .min(by: { ($0.pathComponents.count, $0.relativeMarkdownPath) < ($1.pathComponents.count, $1.relativeMarkdownPath) })
            ?? pages.min(by: { ($0.pathComponents.count, $0.relativeMarkdownPath) < ($1.pathComponents.count, $1.relativeMarkdownPath) })

        var copiedAssetMap: [String: String] = [:] // archive-relative-url -> output-relative-url

        // Render pages.
        for page in pages {
            let destinationURL = outputDirectory.appendingPathComponent(page.relativeMarkdownPath, isDirectory: false)
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            let jsonData = try Data(contentsOf: page.sourceJSON)
            let jsonObject = try JSONSerialization.jsonObject(with: jsonData, options: [])
            guard let node = jsonObject as? [String: Any] else {
                continue
            }

            let markdown = renderMarkdown(
                for: node,
                currentPage: page,
                bookTitle: bookTitle,
                docURLToMarkdownPath: docURLToMarkdownPath,
                inputArchive: inputArchive,
                assetsDirectory: assetsDirectory,
                copiedAssetMap: &copiedAssetMap
            )

            try markdown.data(using: .utf8)?.write(to: destinationURL)
        }

        // Write README.md (copy of landing page content, if available).
        if let landingPage {
            let jsonData = try Data(contentsOf: landingPage.sourceJSON)
            let jsonObject = try JSONSerialization.jsonObject(with: jsonData, options: [])
            if let node = jsonObject as? [String: Any] {
                let readmeMarkdown = renderMarkdown(
                    for: node,
                    currentPage: landingPage,
                    bookTitle: bookTitle,
                    docURLToMarkdownPath: docURLToMarkdownPath,
                    inputArchive: inputArchive,
                    assetsDirectory: assetsDirectory,
                    copiedAssetMap: &copiedAssetMap,
                    forceTopLevelHeading: true
                )
                try readmeMarkdown.data(using: .utf8)?.write(to: outputDirectory.appendingPathComponent("README.md"))
            }
        } else if let bookTitle {
            try "# \(bookTitle)\n".data(using: .utf8)?.write(to: outputDirectory.appendingPathComponent("README.md"))
        }

        // Write SUMMARY.md.
        let summary = generateSummary(pages: pages, outputDirectory: outputDirectory)
        try summary.data(using: .utf8)?.write(to: outputDirectory.appendingPathComponent("SUMMARY.md"))
    }

    // MARK: - Discovery

    private static func discoverPages(in dataDirectory: URL) throws -> [Page] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: dataDirectory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        var pages: [Page] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "json" else { continue }

            let data = try Data(contentsOf: fileURL)
            let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
            guard let node = jsonObject as? [String: Any] else { continue }

            guard let identifier = node["identifier"] as? [String: Any],
                  let docURL = identifier["url"] as? String
            else {
                continue
            }

            let title = extractTitle(from: node) ?? fallbackTitle(from: docURL)
            let (kind, components) = classify(docURL: docURL)

            guard !components.isEmpty else { continue }

            let relativeMarkdownPath = relativeMarkdownPath(kind: kind, pathComponents: components)
            pages.append(
                Page(
                    kind: kind,
                    docURL: docURL,
                    title: title,
                    pathComponents: components,
                    relativeMarkdownPath: relativeMarkdownPath,
                    sourceJSON: fileURL
                )
            )
        }

        // De-duplicate by docURL (some archives can contain multiple JSONs that aren’t render nodes).
        var seen = Set<String>()
        return pages
            .sorted(by: { ($0.kind.rawValue, $0.relativeMarkdownPath) < ($1.kind.rawValue, $1.relativeMarkdownPath) })
            .filter { page in
                guard !seen.contains(page.docURL) else { return false }
                seen.insert(page.docURL)
                return true
            }
    }

    private static func classify(docURL: String) -> (Page.Kind, [String]) {
        guard let url = URL(string: docURL) else {
            return (.other, [])
        }

        let path = url.path
        if let range = path.range(of: "/documentation/") {
            let suffix = String(path[range.upperBound...])
            return (.documentation, pathComponents(from: suffix))
        }

        if let range = path.range(of: "/tutorials/") {
            let suffix = String(path[range.upperBound...])
            return (.tutorials, pathComponents(from: suffix))
        }

        if let range = path.range(of: "/articles/") {
            let suffix = String(path[range.upperBound...])
            return (.articles, pathComponents(from: suffix))
        }

        return (.other, [])
    }

    private static func pathComponents(from suffix: String) -> [String] {
        suffix
            .split(separator: "/")
            .map(String.init)
            .map { $0.removingPercentEncoding ?? $0 }
            .filter { !$0.isEmpty }
    }

    private static func extractTitle(from node: [String: Any]) -> String? {
        if let metadata = node["metadata"] as? [String: Any], let title = metadata["title"] as? String {
            return title
        }

        if let title = node["title"] as? String {
            return title
        }

        return nil
    }

    private static func fallbackTitle(from docURL: String) -> String {
        guard let url = URL(string: docURL) else { return docURL }
        return url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
    }

    private static func relativeMarkdownPath(kind: Page.Kind, pathComponents: [String]) -> String {
        let folder: String
        switch kind {
        case .documentation:
            folder = "reference"
        case .tutorials:
            folder = "tutorials"
        case .articles:
            folder = "articles"
        case .other:
            folder = "other"
        }

        let safeComponents = pathComponents.map(slugify)
        return ([folder] + safeComponents).joined(separator: "/") + ".md"
    }

    private static func slugify(_ input: String) -> String {
        let lowercased = input.lowercased()
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-"))

        let replaced = lowercased
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")

        var result = ""
        var lastWasDash = false
        for scalar in replaced.unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = (scalar == "-")
            } else {
                if !lastWasDash {
                    result.append("-")
                    lastWasDash = true
                }
            }
        }

        while result.contains("--") { result = result.replacingOccurrences(of: "--", with: "-") }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "page" : trimmed
    }

    // MARK: - Rendering

    private static func renderMarkdown(
        for node: [String: Any],
        currentPage: Page,
        bookTitle: String?,
        docURLToMarkdownPath: [String: String],
        inputArchive: URL,
        assetsDirectory: URL,
        copiedAssetMap: inout [String: String],
        forceTopLevelHeading: Bool = false
    ) -> String {
        let title = extractTitle(from: node) ?? currentPage.title

        var markdown = ""

        // GitBook supports YAML frontmatter; keep it minimal.
        markdown += "---\n"
        markdown += "title: \(escapeYAML(title))\n"
        markdown += "---\n\n"

        let headingTitle = forceTopLevelHeading ? (bookTitle ?? title) : title
        markdown += "# \(headingTitle)\n\n"

        let references = (node["references"] as? [String: Any]) ?? [:]

        if let abstract = node["abstract"] {
            let abstractText = renderInlineContent(abstract, references: references, currentPage: currentPage, docURLToMarkdownPath: docURLToMarkdownPath)
            if !abstractText.isEmpty {
                markdown += abstractText + "\n\n"
            }
        }

        if let primaryContentSections = node["primaryContentSections"] as? [[String: Any]] {
            for section in primaryContentSections {
                let kind = section["kind"] as? String
                if kind == "content", let content = section["content"] {
                    markdown += renderBlockContent(
                        content,
                        references: references,
                        currentPage: currentPage,
                        docURLToMarkdownPath: docURLToMarkdownPath,
                        inputArchive: inputArchive,
                        assetsDirectory: assetsDirectory,
                        copiedAssetMap: &copiedAssetMap
                    )
                    if !markdown.hasSuffix("\n") { markdown += "\n" }
                    markdown += "\n"
                }
            }
        }

        return markdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func renderBlockContent(
        _ value: Any,
        references: [String: Any],
        currentPage: Page,
        docURLToMarkdownPath: [String: String],
        inputArchive: URL,
        assetsDirectory: URL,
        copiedAssetMap: inout [String: String]
    ) -> String {
        guard let blocks = value as? [[String: Any]] else {
            return ""
        }

        var result = ""
        for block in blocks {
            result += renderBlock(
                block,
                references: references,
                currentPage: currentPage,
                docURLToMarkdownPath: docURLToMarkdownPath,
                inputArchive: inputArchive,
                assetsDirectory: assetsDirectory,
                copiedAssetMap: &copiedAssetMap
            )
        }
        return result
    }

    private static func renderBlock(
        _ block: [String: Any],
        references: [String: Any],
        currentPage: Page,
        docURLToMarkdownPath: [String: String],
        inputArchive: URL,
        assetsDirectory: URL,
        copiedAssetMap: inout [String: String]
    ) -> String {
        guard let type = block["type"] as? String else {
            return ""
        }

        switch type {
        case "paragraph":
            let inline = block["inlineContent"] ?? block["content"]
            let text = renderInlineContent(inline as Any, references: references, currentPage: currentPage, docURLToMarkdownPath: docURLToMarkdownPath)
            return text.isEmpty ? "" : (text + "\n\n")

        case "heading":
            let level = (block["level"] as? Int) ?? 2
            let inline = block["inlineContent"] ?? block["text"]
            let text = renderInlineContent(inline as Any, references: references, currentPage: currentPage, docURLToMarkdownPath: docURLToMarkdownPath)
            let hashes = String(repeating: "#", count: max(1, min(level, 6)))
            return text.isEmpty ? "" : "\(hashes) \(text)\n\n"

        case "codeListing":
            let code = (block["code"] as? String) ?? ""
            let language = (block["syntax"] as? String) ?? (block["language"] as? String) ?? ""
            if code.isEmpty { return "" }
            return "```\(language)\n\(code)\n```\n\n"

        case "unorderedList":
            guard let items = block["items"] as? [[String: Any]] else { return "" }
            var out = ""
            for item in items {
                let content = item["content"] ?? item["inlineContent"]
                let text = renderInlineContent(content as Any, references: references, currentPage: currentPage, docURLToMarkdownPath: docURLToMarkdownPath)
                if !text.isEmpty {
                    out += "- \(text)\n"
                }
            }
            return out.isEmpty ? "" : (out + "\n")

        case "orderedList":
            guard let items = block["items"] as? [[String: Any]] else { return "" }
            var out = ""
            var index = 1
            for item in items {
                let content = item["content"] ?? item["inlineContent"]
                let text = renderInlineContent(content as Any, references: references, currentPage: currentPage, docURLToMarkdownPath: docURLToMarkdownPath)
                if !text.isEmpty {
                    out += "\(index). \(text)\n"
                    index += 1
                }
            }
            return out.isEmpty ? "" : (out + "\n")

        case "image":
            // RenderNode image blocks typically reference an image in the 'references' dictionary.
            if let identifier = block["identifier"] as? String,
               let reference = references[identifier] as? [String: Any],
               let url = reference["url"] as? String {
                let altText = (reference["alt"] as? String) ?? (reference["title"] as? String) ?? ""
                let resolved = copyAssetIfPossible(
                    referenceURL: url,
                    inputArchive: inputArchive,
                    assetsDirectory: assetsDirectory,
                    copiedAssetMap: &copiedAssetMap
                )
                if let resolved {
                    return "![\(altText)](\(resolved))\n\n"
                }
            }
            return ""

        case "aside":
            let style = (block["style"] as? String) ?? "note"
            let content = block["content"]
            let body = renderBlockContent(
                content as Any,
                references: references,
                currentPage: currentPage,
                docURLToMarkdownPath: docURLToMarkdownPath,
                inputArchive: inputArchive,
                assetsDirectory: assetsDirectory,
                copiedAssetMap: &copiedAssetMap
            )
            if body.isEmpty { return "" }
            let prefix = style.capitalized
            let quoted = body
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
                .map { "> \($0)" }
                .joined(separator: "\n")
            return "> **\(prefix):**\n\(quoted)\n\n"

        default:
            return ""
        }
    }

    private static func renderInlineContent(
        _ value: Any,
        references: [String: Any],
        currentPage: Page,
        docURLToMarkdownPath: [String: String]
    ) -> String {
        // Inline content in RenderNode JSON is typically an array of dictionaries.
        if let array = value as? [[String: Any]] {
            return array.map { renderInline($0, references: references, currentPage: currentPage, docURLToMarkdownPath: docURLToMarkdownPath) }.joined()
        }

        if let string = value as? String {
            return string
        }

        // Some fields are nested under "inlineContent".
        if let dict = value as? [String: Any], let inline = dict["inlineContent"] {
            return renderInlineContent(inline, references: references, currentPage: currentPage, docURLToMarkdownPath: docURLToMarkdownPath)
        }

        return ""
    }

    private static func renderInline(
        _ inline: [String: Any],
        references: [String: Any],
        currentPage: Page,
        docURLToMarkdownPath: [String: String]
    ) -> String {
        guard let type = inline["type"] as? String else { return "" }

        switch type {
        case "text":
            return inline["text"] as? String ?? ""
        case "codeVoice":
            let code = inline["code"] as? String ?? ""
            return code.isEmpty ? "" : "`\(code)`"
        case "emphasis":
            let inner = renderInlineContent(inline["inlineContent"] as Any, references: references, currentPage: currentPage, docURLToMarkdownPath: docURLToMarkdownPath)
            return inner.isEmpty ? "" : "*\(inner)*"
        case "strong":
            let inner = renderInlineContent(inline["inlineContent"] as Any, references: references, currentPage: currentPage, docURLToMarkdownPath: docURLToMarkdownPath)
            return inner.isEmpty ? "" : "**\(inner)**"
        case "reference":
            if let identifier = inline["identifier"] as? String {
                if let reference = references[identifier] as? [String: Any] {
                    let title = (reference["title"] as? String) ?? identifier
                    if let url = reference["url"] as? String {
                        if let link = resolveDocLink(url, currentPage: currentPage, docURLToMarkdownPath: docURLToMarkdownPath) {
                            return "[\(title)](\(link))"
                        }
                    }
                    // Fallback: render title
                    return title
                }

                // Sometimes the identifier is itself a doc:// URL.
                if let link = resolveDocLink(identifier, currentPage: currentPage, docURLToMarkdownPath: docURLToMarkdownPath) {
                    return "[\(identifier)](\(link))"
                }
            }
            return ""
        default:
            return ""
        }
    }

    private static func resolveDocLink(
        _ url: String,
        currentPage: Page,
        docURLToMarkdownPath: [String: String]
    ) -> String? {
        guard url.hasPrefix("doc://") else {
            // External or relative link: keep as-is
            return url
        }

        guard let target = docURLToMarkdownPath[url] else {
            return nil
        }

        let base = URL(fileURLWithPath: currentPage.relativeMarkdownPath).deletingLastPathComponent()
        return relativePath(from: base.path, to: target)
    }

    private static func relativePath(from baseDirectoryPath: String, to targetRelativePath: String) -> String {
        let baseComponents = baseDirectoryPath.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        let targetComponents = targetRelativePath.split(separator: "/").map(String.init).filter { !$0.isEmpty }

        var common = 0
        while common < min(baseComponents.count, targetComponents.count), baseComponents[common] == targetComponents[common] {
            common += 1
        }

        let up = Array(repeating: "..", count: max(0, baseComponents.count - common))
        let down = Array(targetComponents.dropFirst(common))

        let combined = up + down
        return combined.isEmpty ? "./\(URL(fileURLWithPath: targetRelativePath).lastPathComponent)" : combined.joined(separator: "/")
    }

    private static func copyAssetIfPossible(
        referenceURL: String,
        inputArchive: URL,
        assetsDirectory: URL,
        copiedAssetMap: inout [String: String]
    ) -> String? {
        if let existing = copiedAssetMap[referenceURL] {
            return existing
        }

        guard !referenceURL.hasPrefix("http://"), !referenceURL.hasPrefix("https://") else {
            return referenceURL
        }

        // Try resolving relative to archive root.
        let candidate = inputArchive.appendingPathComponent(referenceURL)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: candidate.path) else {
            return nil
        }

        let destination = assetsDirectory.appendingPathComponent(candidate.lastPathComponent)
        try? fileManager.removeItem(at: destination)
        try? fileManager.copyItem(at: candidate, to: destination)

        let resolved = "assets/\(destination.lastPathComponent)"
        copiedAssetMap[referenceURL] = resolved
        return resolved
    }

    private static func escapeYAML(_ input: String) -> String {
        // Minimal YAML escaping for a single-line string.
        let escaped = input.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Summary

    private static func generateSummary(pages: [Page], outputDirectory: URL) -> String {
        var lines: [String] = ["# Summary", "", "* [Introduction](README.md)"]

        // Group by kind and top-level component for stability.
        let filtered = pages.filter { $0.kind != .other }

        let grouped = Dictionary(grouping: filtered, by: { $0.kind })
        let orderedKinds: [Page.Kind] = [.documentation, .articles, .tutorials]

        for kind in orderedKinds {
            guard let kindPages = grouped[kind], !kindPages.isEmpty else { continue }

            // Build a tree from path components.
            let tree = buildTree(for: kindPages)
            for line in treeToSummaryLines(tree, indentLevel: 0) {
                lines.append(line)
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private struct TreeNode {
        var title: String?
        var relativePath: String?
        var children: [String: TreeNode]
    }

    private static func buildTree(for pages: [Page]) -> TreeNode {
        var root = TreeNode(title: nil, relativePath: nil, children: [:])

        for page in pages {
            insert(page: page, into: &root)
        }

        return root
    }

    private static func insert(page: Page, into node: inout TreeNode) {
        guard let first = page.pathComponents.first else { return }
        var child = node.children[first] ?? TreeNode(title: nil, relativePath: nil, children: [:])
        if page.pathComponents.count == 1 {
            child.title = page.title
            child.relativePath = page.relativeMarkdownPath
        } else {
            let remaining = Array(page.pathComponents.dropFirst())
            let nextPage = Page(
                kind: page.kind,
                docURL: page.docURL,
                title: page.title,
                pathComponents: remaining,
                relativeMarkdownPath: page.relativeMarkdownPath,
                sourceJSON: page.sourceJSON
            )
            insert(page: nextPage, into: &child)
        }
        node.children[first] = child
    }

    private static func treeToSummaryLines(_ node: TreeNode, indentLevel: Int) -> [String] {
        var lines: [String] = []

        // Sort by key for deterministic output.
        for key in node.children.keys.sorted() {
            guard let child = node.children[key] else { continue }

            if let title = child.title, let path = child.relativePath {
                let indent = String(repeating: "  ", count: indentLevel)
                lines.append("\(indent)* [\(title)](\(path))")

                // Only indent children if this node produced a bullet.
                let childLines = treeToSummaryLines(child, indentLevel: indentLevel + 1)
                if !childLines.isEmpty {
                    lines.append(contentsOf: childLines)
                }
            } else {
                // No page for this intermediate node; don't increase indentation.
                let childLines = treeToSummaryLines(child, indentLevel: indentLevel)
                if !childLines.isEmpty {
                    lines.append(contentsOf: childLines)
                }
            }
        }

        return lines
    }
}
