// This source file is part of the Swift.org open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for Swift project authors

import Foundation
import SwiftDocCPluginUtilities

private func printUsage() {
    print(
        """
        OVERVIEW: Export a DocC archive (.doccarchive) to a GitBook-compatible Markdown tree.

        USAGE: docc-gitbook-export --input-archive <path> --output-dir <dir> [--book-title <title>]

        OPTIONS:
          --input-archive <path>   Path to a .doccarchive directory.
          --output-dir <dir>       Output directory for GitBook Markdown (README.md, SUMMARY.md, pages, assets).
          --book-title <title>     Optional title for the generated book.
          -h, --help               Show help information.
        """
    )
}

enum CLIError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let string):
            return string
        }
    }
}

func main() throws {
    let argv = Array(CommandLine.arguments.dropFirst())

    if argv.contains("--help") || argv.contains("-h") {
        printUsage()
        return
    }

    func value(after flag: String) -> String? {
        guard let index = argv.firstIndex(of: flag) else { return nil }
        let valueIndex = argv.index(after: index)
        guard valueIndex < argv.endIndex else { return nil }
        return argv[valueIndex]
    }

    let inputArchivePath = value(after: "--input-archive")
    let outputDirPath = value(after: "--output-dir")
    let bookTitle = value(after: "--book-title")

    guard let inputArchivePath, !inputArchivePath.isEmpty else {
        throw CLIError.message("Missing required option: --input-archive")
    }
    guard let outputDirPath, !outputDirPath.isEmpty else {
        throw CLIError.message("Missing required option: --output-dir")
    }

    let inputArchiveURL = URL(fileURLWithPath: inputArchivePath, isDirectory: true)
    let outputDirURL = URL(fileURLWithPath: outputDirPath, isDirectory: true)

    try GitBookExporter.export(inputArchive: inputArchiveURL, outputDirectory: outputDirURL, bookTitle: bookTitle)
}

do {
    try main()
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
