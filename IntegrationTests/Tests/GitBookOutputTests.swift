// This source file is part of the Swift.org open source project
//
// Copyright (c) 2022-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for Swift project authors

import Foundation
import XCTest

final class GitBookOutputTests: ConcurrencyRequiringTestCase {
    func testGenerateDocumentationAsGitBookMarkdown() throws {
        let result = try swiftPackage(
            "generate-documentation",
            "--output-format", "gitbook",
            workingDirectory: try setupTemporaryDirectoryForFixture(named: "SingleLibraryTarget")
        )

        result.assertExitStatusEquals(0)

        let gitbookOutputDirectory = try XCTUnwrap(
            result.gitbookOutputDirectory,
            "Expected plugin to print the GitBook output directory path"
        )

        let filePaths = try relativeFilePathsIn(gitbookOutputDirectory)
        XCTAssertTrue(filePaths.contains("README.md"))
        XCTAssertTrue(filePaths.contains("SUMMARY.md"))

        XCTAssertTrue(
            filePaths.contains(where: { $0.hasSuffix(".md") && $0 != "README.md" && $0 != "SUMMARY.md" }),
            "Expected at least one additional Markdown page"
        )
    }
}

private extension SwiftInvocationResult {
    var gitbookOutputDirectory: URL? {
        let outputLines = standardOutput.components(separatedBy: .newlines)

        let markers = [
            "Generated GitBook Markdown documentation at:",
            "Generated combined GitBook Markdown documentation at:",
        ]

        for marker in markers {
            if let index = outputLines.firstIndex(where: { $0.contains(marker) }) {
                for line in outputLines[(index + 1)...] {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    return URL(fileURLWithPath: trimmed)
                }
            }
        }

        return nil
    }
}
