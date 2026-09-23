import Foundation

/// Decodes Parakeet's SentencePiece-style BPE ids (`tokenizer.json`, Metaspace `▁` word marks).
struct Tokenizer {
    private let pieces: [String]
    private let skipped: Set<Int>

    init(url: URL) throws {
        struct File: Decodable {
            struct Model: Decodable { let vocab: [String: Int] }
            struct Added: Decodable { let id: Int }
            let model: Model
            let addedTokens: [Added]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let file = try decoder.decode(File.self, from: Data(contentsOf: url))
        var pieces = [String](repeating: "", count: file.model.vocab.count)
        for (piece, id) in file.model.vocab where id < pieces.count {
            pieces[id] = piece
        }
        self.pieces = pieces
        // <unk>, <pad> and the <|…|> control tokens never belong in a transcript.
        skipped = Set(file.addedTokens.map(\.id))
    }

    func decode(_ ids: [Int]) -> String {
        var text = ""
        for id in ids where id < pieces.count && !skipped.contains(id) {
            text += pieces[id]
        }
        return text.replacingOccurrences(of: "\u{2581}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
