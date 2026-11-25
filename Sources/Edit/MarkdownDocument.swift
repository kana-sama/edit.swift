import Foundation
import JavaScriptCore

struct MarkdownViewState: Codable, Equatable, Sendable {
    struct Reading: Codable, Equatable, Sendable {
        var sourceOffset: Int
        var offsetIntoBlock: Double = 0
        var disclosures: [String: Bool] = [:]

        var arguments: [String: Any] {
            ["sourceOffset": sourceOffset, "offsetIntoBlock": offsetIntoBlock, "disclosures": disclosures]
        }
    }

    var showsPreview = false
    var reading: Reading?
}

struct MarkdownRevisionRecord: Codable, Sendable {
    let root: URL
    let path: String
    let commit: String
    let operation: String

    struct Loaded: Sendable {
        let workspace: JJWorkspace
        let file: JJSourceControlFile
        let revision: JJSourceControlRevision
        let operation: String
        let preview: SourceControlRevisionPreview
    }

    func load() async throws -> Loaded {
        guard let workspace = await JJRepository.discover(at: root) else { throw CocoaError(.fileReadNoSuchFile) }
        let revision = try await JJSourceControlRepository.savedRevision(commit, in: workspace, at: operation)
        let files = try await JJSourceControlRepository.changedFiles(commit, in: workspace, at: operation)
        let file: JJSourceControlFile
        if let changed = files.first(where: { $0.path == path }) { file = changed }
        else { file = try await JJSourceControlRepository.linkedFile(path, in: revision, workspace: workspace, at: operation) }
        let contents = try await JJSourceControlRepository.file(file, in: revision, workspace: workspace, at: operation)
        let url = workspace.root.appending(path: path, directoryHint: .notDirectory)
        let preview = try await SourceControlRevisionPreview.prepare(contents, file: file, revision: revision, at: url)
        return Loaded(workspace: workspace, file: file, revision: revision, operation: operation, preview: preview)
    }
}

struct MarkdownDocument: Decodable, Sendable {
    struct Link: Decodable, Sendable {
        let start: Int
        let end: Int
        let target: String?
        let destination: Int?
        let references: [Int]?
        let note: String?
    }

    struct Code: Decodable, Sendable {
        let language: String
        let text: String

        func highlighted() -> String {
            let name = language.lowercased()
            let mode = SyntaxLanguage(rawValue: name) ?? .detected(at: URL(fileURLWithPath: "fence.\(name)"))
            guard mode != .plainText, let analysis = SyntaxEngine.analysis(in: text, language: mode, includesBrackets: false) else {
                return ""
            }
            let source = text as NSString
            var start = 0
            var html = ""
            for span in analysis.spans {
                if span.start > start { html += Self.escape(source.substring(with: NSRange(location: start, length: span.start - start))) }
                let token = source.substring(with: NSRange(location: span.start, length: span.end - span.start))
                html += "<span class=\"syntax-\(span.color)\">\(Self.escape(token))</span>"
                start = span.end
            }
            return html + Self.escape(source.substring(from: start))
        }

        private static func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
    }

    let html: String
    let anchors: [String: Int]
    let links: [Link]
    let images: [String]
    let code: [Code]
}

enum MarkdownAssets {
    static func text(_ file: String) throws -> String {
        guard let url = Bundle.main.resourceURL?.appending(path: "markdown/\(file)") else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

actor MarkdownDocumentRenderer {
    static let shared = MarkdownDocumentRenderer()
    private var context: JSContext?

    func render(_ source: String, includeHTML: Bool) throws -> MarkdownDocument {
        try Task.checkCancellation()
        let context: JSContext
        if let existing = self.context {
            context = existing
        } else {
            guard let created = JSContext() else { throw CocoaError(.featureUnsupported) }
            created.evaluateScript(try MarkdownAssets.text("render.js"))
            self.context = created
            context = created
        }
        context.exception = nil
        let value = context.objectForKeyedSubscript("EditMarkdown")?.invokeMethod("render", withArguments: [source, includeHTML])
        guard context.exception == nil, let value, value.isString, let json = value.toString() else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try Task.checkCancellation()
        return try JSONDecoder().decode(MarkdownDocument.self, from: Data(json.utf8))
    }
}
