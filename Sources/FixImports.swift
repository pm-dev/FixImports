//
//  File.swift
//  
//
//  Created by Peter Meyers on 4/16/24.
//

import Foundation
import ArgumentParser

@main
struct FixImports: AsyncParsableCommand {
    @Option(help: """
        Specify the build output file that contains the 'Cannot find type <type> in scope' errors.
        By default this script looks for 'output.txt' inside the FixImports directory
        """
    )
    public var buildFile: String = URL(string: #file)!
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .absoluteString + "output.txt"

    mutating func run() async throws {
        guard FileManager.default.fileExists(atPath: buildFile) else {
            throw ValidationError("File doesn't exist at \(buildFile)")
        }
        guard let handle = FileHandle(forReadingAtPath: buildFile) else {
            throw ValidationError("File doesn't exist at \(buildFile)")
        }
        try await searchFile(handle)
    }

    private func searchFile(_ handle: FileHandle) async throws {
        print("Searching build log for broken references. This takes a couple mins...")
        let brokenReferences = try await handle.bytes.lines.compactMap { line in
            try? searchLine(line)
        }.reduce(into: [String: Set<String>]()) { result, brokenReference in
            if var paths = result[brokenReference.type] {
                paths.insert(brokenReference.filePath)
                result[brokenReference.type] = paths
            } else {
                result[brokenReference.type] = [brokenReference.filePath]
            }
        }
        print("""
        Found \(brokenReferences.count) types that are not found: \(brokenReferences.keys.joined(separator: ", "))
        """)
        try await fixBrokenReferences(brokenReferences)
    }

    struct BrokenReference {
        static let regex = /^(?<foundPath>\/.+\.swift):\d+:\d+: error: cannot find '(?<foundType>\w+)' in scope/
        let type: String
        let filePath: String

        init(type: Substring, filePath: Substring) {
            self.type = String(type)
            self.filePath = String(filePath)
        }
    }

    private func searchLine(_ buildOutputLine: String) throws -> BrokenReference? {
        if let match = try BrokenReference.regex.firstMatch(in: buildOutputLine) {
            print("Broken reference of \(match.output.foundType) found in: \(match.output.foundPath)")
            return BrokenReference(type: match.output.foundType, filePath: match.output.foundPath)
        } else {
            return nil
        }
    }

    private func fixBrokenReferences(_ brokenReferences: [String: Set<String>]) async throws {
        for (type, paths) in brokenReferences {
            try await fixBrokenReference(type: type, paths: paths)
        }
    }

    private func fixBrokenReference(type: String, paths: Set<String>) async throws {
        print("What module is \(type) located in?")
        guard let module = readLine(), !module.isEmpty else {
            try await fixBrokenReference(type: type, paths: paths)
            return
        }
        let importStmt = "import \(module)\n"
        for path in paths {
            guard let fileForWriting = FileHandle(forWritingAtPath: path) else {
                print("Failed to open file for writing. Skipping: \(path)")
                continue
            }
            var fileContents = try String(contentsOfFile: path, encoding: .utf8)
            if fileContents.contains(importStmt) {
                continue
            }
            guard let firstImportRange = fileContents.firstRange(of: "import") else {
                print("One import stmt is needed in file to know where to add the new import stmt. Skipping: \(path)")
                continue
            }
            fileContents.insert(contentsOf: importStmt, at: firstImportRange.lowerBound)
            guard let data = fileContents.data(using: .utf8) else {
                print("Failed to convert file contents to data. Skipping: \(path)")
                continue
            }
            try fileForWriting.seek(toOffset: 0)
            try fileForWriting.write(contentsOf: data)
            try fileForWriting.close()
            print("Fixed \(path)")
        }
    }
}
