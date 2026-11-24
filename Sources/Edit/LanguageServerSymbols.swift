import Foundation

struct LSPSymbol: Sendable {
    let name: String
    let detail: String?
    let kind: Int
    let location: LSPLocation
}

enum LSPDocumentSymbols: Decodable, Sendable {
    case hierarchical([DocumentSymbol]), flat([SymbolInformation])

    struct DocumentSymbol: Decodable, Sendable {
        let name: String
        let detail: String?
        let kind: Int
        let selectionRange: LSPRange
        let children: [Self]?

        fileprivate func append(to symbols: inout [LSPSymbol], url: URL, container: String?) {
            let context = [container, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            symbols.append(LSPSymbol(name: name, detail: context.isEmpty ? nil : context, kind: kind,
                                     location: LSPLocation(url: url, range: selectionRange)))
            let qualified = container.map { $0 + "." + name } ?? name
            for child in children ?? [] { child.append(to: &symbols, url: url, container: qualified) }
        }
    }

    struct SymbolInformation: Decodable, Sendable {
        let name: String
        let kind: Int
        let location: LSPLocation
        let containerName: String?

        var symbol: LSPSymbol { LSPSymbol(name: name, detail: containerName, kind: kind, location: location) }
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let symbols = try? value.decode([DocumentSymbol].self) { self = .hierarchical(symbols) }
        else { self = .flat(try value.decode([SymbolInformation].self)) }
    }

    func symbols(in url: URL) -> [LSPSymbol] {
        switch self {
        case .hierarchical(let children):
            var symbols: [LSPSymbol] = []
            for child in children { child.append(to: &symbols, url: url, container: nil) }
            return symbols
        case .flat(let symbols):
            return symbols.map(\.symbol)
        }
    }
}
