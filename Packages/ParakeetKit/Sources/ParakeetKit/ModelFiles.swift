import Foundation

/// The pinned Hugging Face snapshot of `moondream/parakeet-redux` the engine is built against.
public enum ModelFiles {
    public static let repository = "moondream/parakeet-redux"
    public static let revision = "ab9eb5ef7b81f98211b3feb68e5a856cab71f913"

    public struct File: Sendable, Hashable {
        public let name: String
        public let size: Int64
        /// SHA-256 of the file contents, when Hugging Face publishes one (LFS files).
        public let sha256: String?
    }

    public static let files: [File] = [
        File(name: "config.json", size: 12_988, sha256: nil),
        File(name: "tokenizer.json", size: 1_159_960, sha256: nil),
        File(name: "ternary.json", size: 57_970, sha256: nil),
        File(
            name: "model.safetensors", size: 177_774_490,
            sha256: "78ec25733ee0d0c1586d1346fc86db9d0c2e436e3a8ab1d32a82d1bb8f848d21"),
    ]

    public static var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    public static func remoteURL(for file: File) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.name)")!
    }

    /// `~/Library/Application Support/NoType/Models/parakeet-redux/<revision>`
    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: "NoType/Models/parakeet-redux/\(revision)", directoryHint: .isDirectory)
    }

    /// True when every file is present with the expected size. Hashes are checked once, at download.
    public static func isComplete(at directory: URL = defaultDirectory) -> Bool {
        files.allSatisfy { file in
            let url = directory.appending(path: file.name)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size])
                as? Int64
            return size == file.size
        }
    }
}

/// The audio format the engine expects.
public enum SpeechAudio {
    public static let sampleRate = 16_000
    /// Shorter clips cannot be normalized and come back as an empty transcript.
    public static let minimumSamples = Features.minimumSamples
}
