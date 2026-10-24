import Foundation

/// The byte-range arithmetic of chunked link downloads (LinkDownloads.swift): the Range header for each chunk and the
/// file's total size from the server's Content-Range. Pure Foundation, so mac/tools/test-linkmedia.sh checks on
/// Linux that the chunks cover a file exactly once, with no gap and no byte twice.
enum LinkChunks {
    /// The Range header for the chunk starting at `offset` (inclusive on both ends, as HTTP ranges are).
    static func rangeHeader(offset: Int64, chunk: Int64) -> String {
        "bytes=\(offset)-\(offset + chunk - 1)"
    }

    /// The whole file's size from a Content-Range header ("bytes 0-8388607/59514321"). Nil when it's unknown ("*").
    static func total(contentRange: String?) -> Int64? {
        contentRange.flatMap { $0.split(separator: "/").last }.flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    }
}
