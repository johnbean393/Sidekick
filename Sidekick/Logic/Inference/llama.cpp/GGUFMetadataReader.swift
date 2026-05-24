//
//  GGUFMetadataReader.swift
//  Sidekick
//
//  Reads metadata from a GGUF file. The format is described in
//  https://github.com/ggerganov/ggml/blob/master/docs/gguf.md
//
//  We only inspect metadata; tensor data is skipped. To keep startup latency
//  low and memory pressure flat, the parser streams the file in small chunks
//  rather than mmaping or loading it whole.
//

import Foundation
import OSLog

public struct GGUFMetadataReader {
    
    fileprivate static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Sidekick",
        category: String(describing: GGUFMetadataReader.self)
    )
    
    private static let magic: [UInt8] = [0x47, 0x47, 0x55, 0x46] // "GGUF"
    
    /// Reasonable upper bounds so a malformed file can't trigger runaway
    /// allocations.
    fileprivate static let maxStringLength: UInt64 = 16 * 1024 * 1024  // 16 MiB
    fileprivate static let maxArrayLength: UInt64 = 1 << 22            // 4 194 304
    private static let maxKvCount: UInt64 = 1 << 20                    // 1 048 576
    
    public enum ValueType: UInt32 {
        case uint8 = 0
        case int8 = 1
        case uint16 = 2
        case int16 = 3
        case uint32 = 4
        case int32 = 5
        case float32 = 6
        case bool = 7
        case string = 8
        case array = 9
        case uint64 = 10
        case int64 = 11
        case float64 = 12
    }
    
    public struct ChatTemplateInfo {
        /// The default `tokenizer.chat_template` string, if present.
        public let defaultTemplate: String?
        /// Named template variants like `tool_use`, keyed by the suffix of
        /// `tokenizer.chat_template.<name>`.
        public let namedTemplates: [String: String]
    }

    /// Snapshot of the architecture-dependent fields useful for sizing
    /// the KV cache without invoking an external estimator. Populated
    /// from `general.architecture` and `{arch}.*` keys.
    public struct ArchitectureInfo {
        public let architecture: String?
        public let contextLength: Int?
    }

    /// Read the trained context length and architecture name from a
    /// GGUF file. Falls back to `nil` for any field that is missing or
    /// has an unexpected type.
    public static func readArchitectureInfo(
        from url: URL
    ) -> ArchitectureInfo? {
        guard let stream = GGUFStream(url: url) else {
            return nil
        }
        defer { stream.close() }

        do {
            var magicBytes = [UInt8](repeating: 0, count: 4)
            try stream.read(into: &magicBytes, count: 4)
            guard magicBytes == magic else {
                return nil
            }
            let version: UInt32 = try stream.readUInt32()
            guard version >= 1 && version <= 3 else {
                return nil
            }
            let useWideCounts = version >= 2
            _ = try stream.readCount(wide: useWideCounts)
            let kvCount = try stream.readCount(wide: useWideCounts)
            guard kvCount <= maxKvCount else {
                return nil
            }
            var architecture: String? = nil
            // First pass: scan for `general.architecture` and any
            // `*.context_length`. Since GGUF metadata can be in any
            // order, we collect every `*.context_length` we see and
            // resolve at the end against the architecture we found.
            var contextLengthByKey: [String: Int] = [:]
            for _ in 0..<kvCount {
                let key = try stream.readString(wide: useWideCounts)
                let valueType = try stream.readValueType()
                if key == "general.architecture" {
                    guard valueType == .string else {
                        try stream.skipValue(of: valueType, wide: useWideCounts)
                        continue
                    }
                    architecture = try stream.readString(wide: useWideCounts)
                } else if key.hasSuffix(".context_length") {
                    if let value = try Self.readIntegerValue(stream: stream, type: valueType, wide: useWideCounts) {
                        contextLengthByKey[key] = value
                    }
                } else {
                    try stream.skipValue(of: valueType, wide: useWideCounts)
                }
            }
            let contextLength: Int? = {
                if let arch = architecture,
                   let value = contextLengthByKey["\(arch).context_length"] {
                    return value
                }
                // Fallback: take the first `.context_length` we found.
                // GGUFs that name the field with the wrong architecture
                // prefix do exist in the wild.
                return contextLengthByKey.values.first
            }()
            return ArchitectureInfo(
                architecture: architecture,
                contextLength: contextLength
            )
        } catch {
            Self.logger.warning(
                "Failed to parse GGUF architecture info for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Decode an integer-typed GGUF value into a signed `Int`,
    /// returning `nil` (and skipping the value) for incompatible types.
    private static func readIntegerValue(
        stream: GGUFStream,
        type: ValueType,
        wide: Bool
    ) throws -> Int? {
        switch type {
            case .uint8: return Int(try stream.readUInt8())
            case .int8:  return Int(try stream.readInt8())
            case .uint16: return Int(try stream.readUInt16())
            case .int16: return Int(try stream.readInt16())
            case .uint32: return Int(try stream.readUInt32())
            case .int32: return Int(try stream.readInt32())
            case .uint64:
                let value = try stream.readUInt64()
                return value > UInt64(Int.max) ? nil : Int(value)
            case .int64: return Int(try stream.readInt64())
            default:
                try stream.skipValue(of: type, wide: wide)
                return nil
        }
    }
    
    /// Read the chat-template family of metadata keys from the given GGUF
    /// file. Returns `nil` when the file is missing, unreadable, or not a
    /// valid GGUF.
    public static func readChatTemplateInfo(
        from url: URL
    ) -> ChatTemplateInfo? {
        guard let stream = GGUFStream(url: url) else {
            return nil
        }
        defer { stream.close() }
        
        do {
            var magicBytes = [UInt8](repeating: 0, count: 4)
            try stream.read(into: &magicBytes, count: 4)
            guard magicBytes == magic else {
                return nil
            }
            let version: UInt32 = try stream.readUInt32()
            guard version >= 1 && version <= 3 else {
                return nil
            }
            // GGUF v1 used uint32 counts; v2+ use uint64.
            let useWideCounts = version >= 2
            // tensor_count, then metadata_kv_count
            _ = try stream.readCount(wide: useWideCounts)
            let kvCount = try stream.readCount(wide: useWideCounts)
            guard kvCount <= maxKvCount else {
                return nil
            }
            
            var defaultTemplate: String? = nil
            var namedTemplates: [String: String] = [:]
            
            for _ in 0..<kvCount {
                let key = try stream.readString(wide: useWideCounts)
                let valueType = try stream.readValueType()
                
                if key == "tokenizer.chat_template" {
                    guard valueType == .string else {
                        try stream.skipValue(of: valueType, wide: useWideCounts)
                        continue
                    }
                    defaultTemplate = try stream.readString(wide: useWideCounts)
                } else if key.hasPrefix("tokenizer.chat_template.") {
                    let name = String(key.dropFirst("tokenizer.chat_template.".count))
                    guard valueType == .string else {
                        try stream.skipValue(of: valueType, wide: useWideCounts)
                        continue
                    }
                    let body = try stream.readString(wide: useWideCounts)
                    namedTemplates[name] = body
                } else {
                    try stream.skipValue(of: valueType, wide: useWideCounts)
                }
            }
            
            return ChatTemplateInfo(
                defaultTemplate: defaultTemplate,
                namedTemplates: namedTemplates
            )
        } catch {
            Self.logger.warning(
                "Failed to parse GGUF metadata for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
    
    /// Returns `true` when the model's GGUF ships a chat template that knows
    /// how to render and emit tool calls. When `true`, passing `--jinja` to
    /// `llama-server` lets the server's chat engine bias and parse tool calls
    /// correctly; when `false`, `--jinja` either errors out (no template) or
    /// produces a generic format that may emit text-mode tool calls the
    /// client can't recover.
    public static func modelSupportsToolAwareJinja(
        at url: URL
    ) -> Bool {
        let cacheKey = CacheKey(url: url)
        if let cached = cache.value(for: cacheKey) {
            return cached
        }
        guard let info = readChatTemplateInfo(from: url) else {
            Self.logger.notice(
                "GGUF at \(url.lastPathComponent, privacy: .public) has no readable metadata; assuming no tool-aware template"
            )
            cache.set(false, for: cacheKey)
            return false
        }
        // A dedicated `tool_use` variant is a definitive signal (Hermes 2 Pro,
        // Hermes 3, several Llama-3-derived tunes ship one).
        if info.namedTemplates["tool_use"] != nil {
            Self.logger.info(
                "GGUF \(url.lastPathComponent, privacy: .public) ships a `tool_use` template variant; enabling --jinja"
            )
            cache.set(true, for: cacheKey)
            return true
        }
        let candidates: [String] = ([info.defaultTemplate].compactMap { $0 })
            + Array(info.namedTemplates.values)
        let supports = candidates.contains(where: templateMentionsTools)
        if supports {
            Self.logger.info(
                "GGUF \(url.lastPathComponent, privacy: .public) chat template references tool calls; enabling --jinja"
            )
        } else if info.defaultTemplate == nil && info.namedTemplates.isEmpty {
            Self.logger.notice(
                "GGUF \(url.lastPathComponent, privacy: .public) has no embedded chat template; --jinja would fail, leaving it off"
            )
        } else {
            Self.logger.notice(
                "GGUF \(url.lastPathComponent, privacy: .public) has a chat template but no tool-call markers; leaving --jinja off"
            )
        }
        cache.set(supports, for: cacheKey)
        return supports
    }
    
    private static func templateMentionsTools(_ template: String) -> Bool {
        // Substrings that appear in every common tool-aware Jinja template
        // (Hermes / Qwen / Llama 3.x / Mistral Nemo / Functionary /
        // Firefunction / Command R). Either the Jinja-side variable reference
        // (`tools`, `tool_call`, …) or the literal sentinels the template
        // would emit (`<|python_tag|>`, `<function=`, …) are sufficient.
        let needles: [String] = [
            "tools",
            "tool_call",
            "tool_calls",
            "function_call",
            "<|python_tag|>",
            "<function=",
            "[TOOL_CALLS]"
        ]
        return needles.contains { template.contains($0) }
    }
    
    // MARK: Caching
    
    /// Identity of a GGUF file on disk: path plus mtime plus size. This makes
    /// the cache transparent to model swaps and to rebuilds in place.
    private struct CacheKey: Hashable {
        let path: String
        let modificationDate: Date?
        let size: UInt64?
        
        init(url: URL) {
            self.path = url.path
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            self.modificationDate = attrs?[.modificationDate] as? Date
            self.size = (attrs?[.size] as? NSNumber)?.uint64Value
        }
    }
    
    private static let cache = Cache<CacheKey, Bool>()
    
    private final class Cache<Key: Hashable, Value> {
        private var storage: [Key: Value] = [:]
        private let queue = DispatchQueue(label: "Sidekick.GGUFMetadataReader.cache")
        func value(for key: Key) -> Value? {
            queue.sync { storage[key] }
        }
        func set(_ value: Value, for key: Key) {
            queue.sync { storage[key] = value }
        }
    }
    
}

// MARK: - Streaming reader

/// Tiny buffered reader over a `FileHandle`. Lets us peek a few bytes at a
/// time without slurping the GGUF (multi-GB) or maintaining an `mmap`.
private final class GGUFStream {
    private let handle: FileHandle
    private var buffer = Data()
    private var bufferOffset = 0
    private let chunkSize = 64 * 1024
    
    enum ReadError: Error {
        case endOfFile
        case invalidValueType(UInt32)
        case unsupportedValueInArray
        case overflow
        case stringTooLong
        case arrayTooLong
    }
    
    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        self.handle = handle
    }
    
    func close() {
        try? handle.close()
    }
    
    private func ensure(_ count: Int) throws {
        while buffer.count - bufferOffset < count {
            let needed = max(chunkSize, count - (buffer.count - bufferOffset))
            let chunk = handle.readData(ofLength: needed)
            if chunk.isEmpty {
                throw ReadError.endOfFile
            }
            if bufferOffset > 0 {
                buffer.removeSubrange(0..<bufferOffset)
                bufferOffset = 0
            }
            buffer.append(chunk)
        }
    }
    
    func read(into out: UnsafeMutablePointer<UInt8>, count: Int) throws {
        guard count > 0 else { return }
        try ensure(count)
        buffer.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: bufferOffset)
            out.update(from: base.assumingMemoryBound(to: UInt8.self), count: count)
        }
        bufferOffset += count
    }
    
    func read(into out: inout [UInt8], count: Int) throws {
        try out.withUnsafeMutableBufferPointer {
            try read(into: $0.baseAddress!, count: count)
        }
    }
    
    /// Discard `count` bytes from the stream. Seeks the underlying file
    /// forward when the buffer doesn't contain enough — avoids reading and
    /// throwing away large array payloads.
    func skip(_ count: Int) throws {
        guard count > 0 else { return }
        let available = buffer.count - bufferOffset
        if available >= count {
            bufferOffset += count
            return
        }
        let remaining = count - available
        buffer.removeAll(keepingCapacity: true)
        bufferOffset = 0
        let pos = (try? handle.offset()) ?? 0
        try handle.seek(toOffset: pos + UInt64(remaining))
    }
    
    func readUInt8() throws -> UInt8 {
        var byte: UInt8 = 0
        try withUnsafeMutablePointer(to: &byte) { ptr in
            try read(into: ptr, count: 1)
        }
        return byte
    }

    func readInt8() throws -> Int8 {
        return Int8(bitPattern: try readUInt8())
    }

    func readUInt16() throws -> UInt16 {
        var bytes = [UInt8](repeating: 0, count: 2)
        try read(into: &bytes, count: 2)
        return bytes.withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
    }

    func readInt16() throws -> Int16 {
        return Int16(bitPattern: try readUInt16())
    }

    func readUInt32() throws -> UInt32 {
        var bytes = [UInt8](repeating: 0, count: 4)
        try read(into: &bytes, count: 4)
        return bytes.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    }

    func readInt32() throws -> Int32 {
        return Int32(bitPattern: try readUInt32())
    }

    func readUInt64() throws -> UInt64 {
        var bytes = [UInt8](repeating: 0, count: 8)
        try read(into: &bytes, count: 8)
        return bytes.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
    }

    func readInt64() throws -> Int64 {
        return Int64(bitPattern: try readUInt64())
    }
    
    func readCount(wide: Bool) throws -> UInt64 {
        return wide ? try readUInt64() : UInt64(try readUInt32())
    }
    
    func readValueType() throws -> GGUFMetadataReader.ValueType {
        let raw = try readUInt32()
        guard let type = GGUFMetadataReader.ValueType(rawValue: raw) else {
            throw ReadError.invalidValueType(raw)
        }
        return type
    }
    
    func readString(wide: Bool) throws -> String {
        let length = try readCount(wide: wide)
        if length > GGUFMetadataReader.maxStringLength {
            throw ReadError.stringTooLong
        }
        let count = Int(length)
        guard count >= 0 else { throw ReadError.overflow }
        if count == 0 { return "" }
        var bytes = [UInt8](repeating: 0, count: count)
        try read(into: &bytes, count: count)
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
    
    func skipString(wide: Bool) throws {
        let length = try readCount(wide: wide)
        if length > GGUFMetadataReader.maxStringLength {
            throw ReadError.stringTooLong
        }
        try skip(Int(length))
    }
    
    func skipValue(of type: GGUFMetadataReader.ValueType, wide: Bool) throws {
        switch type {
            case .string:
                try skipString(wide: wide)
            case .array:
                let elementType = try readValueType()
                let count = try readCount(wide: wide)
                try skipArrayElements(of: elementType, count: count, wide: wide)
            default:
                try skipScalar(of: type)
        }
    }
    
    private func skipScalar(of type: GGUFMetadataReader.ValueType) throws {
        switch type {
            case .uint8, .int8, .bool:
                try skip(1)
            case .uint16, .int16:
                try skip(2)
            case .uint32, .int32, .float32:
                try skip(4)
            case .uint64, .int64, .float64:
                try skip(8)
            case .string, .array:
                throw ReadError.unsupportedValueInArray
        }
    }
    
    func skipArrayElements(
        of elementType: GGUFMetadataReader.ValueType,
        count: UInt64,
        wide: Bool
    ) throws {
        if count > GGUFMetadataReader.maxArrayLength {
            throw ReadError.arrayTooLong
        }
        switch elementType {
            case .string:
                for _ in 0..<count {
                    try skipString(wide: wide)
                }
            case .array:
                // Nested arrays exist but are very rare in metadata; handle
                // them recursively in case a GGUF in the wild uses them.
                for _ in 0..<count {
                    let nestedType = try readValueType()
                    let nestedCount = try readCount(wide: wide)
                    try skipArrayElements(
                        of: nestedType,
                        count: nestedCount,
                        wide: wide
                    )
                }
            default:
                let bytesPerElement: Int
                switch elementType {
                    case .uint8, .int8, .bool: bytesPerElement = 1
                    case .uint16, .int16: bytesPerElement = 2
                    case .uint32, .int32, .float32: bytesPerElement = 4
                    case .uint64, .int64, .float64: bytesPerElement = 8
                    case .string, .array:
                        throw ReadError.unsupportedValueInArray
                }
                try skip(bytesPerElement * Int(count))
        }
    }
}
