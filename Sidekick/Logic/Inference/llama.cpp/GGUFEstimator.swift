//
//  GGUFEstimator.swift
//  Sidekick
//
//  Wraps the bundled `gguf-parser` (https://github.com/gpustack/gguf-parser-go)
//  binary so the load-config sheet can estimate the largest `n_ctx` that
//  fits in unified memory before the model is loaded.
//
//  Strategy: probe `gguf-parser` twice — once at a small context size and
//  once at the model's trained maximum — to derive a per-token KV cost
//  via linear interpolation. Most architectures grow KV linearly with
//  context length, so two probes plus the base cost are enough to
//  estimate the safe ceiling without doing a full binary search.
//

import Darwin
import Foundation
import OSLog

public enum GGUFEstimatorError: Error {
    case binaryNotFound
    case nonZeroExit(Int32, String)
    case malformedOutput(String)
    case metadataUnavailable
}

public struct GGUFEstimator {

    fileprivate static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier ?? "Sidekick",
        category: String(describing: GGUFEstimator.self)
    )

    /// Result of estimating the safe context-length ceiling for a model.
    public struct Estimate: Equatable {
        /// The model's trained context length, as advertised by its
        /// GGUF metadata.
        public let trainedContextLength: Int
        /// Largest context length that should fit comfortably in the
        /// host's unified memory after applying the headroom reserve.
        /// Always `<= trainedContextLength`.
        public let safeMaxContextLength: Int
        /// Estimated total bytes the model + KV cache + compute buffer
        /// would consume at `safeMaxContextLength` (UMA path).
        public let estimatedBytesAtSafeMax: UInt64
        /// Estimated total bytes at a 4K context (i.e. base cost
        /// without much KV) — useful for the sheet header.
        public let estimatedBytesAtBaseline: UInt64
        /// Snapshot of the available memory budget used to compute
        /// `safeMaxContextLength`.
        public let availableMemoryBytes: UInt64
        /// `availableMemoryBytes / (1024^3)` for cache invalidation.
        public let availableMemoryGB: Int
    }

    /// Compute an `Estimate` for the given GGUF file. Throws if the
    /// estimator binary is missing or returns malformed output. Safe to
    /// call from any actor — the underlying `Process` runs on a
    /// detached task.
    public static func estimate(
        model url: URL,
        availableMemoryBytes: UInt64,
        headroomFraction: Double = 0.20
    ) async throws -> Estimate {
        let usableBytes = UInt64(
            (Double(availableMemoryBytes) * (1.0 - headroomFraction))
                .rounded(.down)
        )
        // Two probes: small ctx for the base cost (model weights +
        // compute buffer), trained-max ctx for the upper bound. We
        // derive a linear fit between them, then solve for the largest
        // ctx that still fits inside `usableBytes`.
        let baselineCtx: Int = 4_096
        let smallProbe = try await runProbe(modelUrl: url, ctxSize: baselineCtx)
        let trainedMax = max(baselineCtx, smallProbe.maxContextLength)
        let largeProbe: Probe
        if trainedMax == baselineCtx {
            largeProbe = smallProbe
        } else {
            largeProbe = try await runProbe(modelUrl: url, ctxSize: trainedMax)
        }
        let safeMaxCtx = solveSafeMax(
            smallCtx: baselineCtx,
            smallBytes: smallProbe.umaBytes,
            largeCtx: trainedMax,
            largeBytes: largeProbe.umaBytes,
            trainedMax: trainedMax,
            usableBytes: usableBytes
        )
        let estimatedAtSafeMax = interpolate(
            ctx: safeMaxCtx,
            smallCtx: baselineCtx,
            smallBytes: smallProbe.umaBytes,
            largeCtx: trainedMax,
            largeBytes: largeProbe.umaBytes
        )
        let availableGB = Int(availableMemoryBytes / (1024 * 1024 * 1024))
        return Estimate(
            trainedContextLength: trainedMax,
            safeMaxContextLength: safeMaxCtx,
            estimatedBytesAtSafeMax: estimatedAtSafeMax,
            estimatedBytesAtBaseline: smallProbe.umaBytes,
            availableMemoryBytes: availableMemoryBytes,
            availableMemoryGB: availableGB
        )
    }

    // MARK: - Memory helpers

    /// Total physical memory of the host, in bytes. On Apple Silicon
    /// this is unified memory.
    public static func unifiedMemoryBytes() -> UInt64 {
        return ProcessInfo.processInfo.physicalMemory
    }

    /// Best-effort estimate of memory currently free. Used to size the
    /// available budget when the user hasn't explicitly set one.
    public static func availableMemoryBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count: mach_msg_type_number_t = UInt32(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ptr in
                host_statistics64(
                    mach_host_self(),
                    HOST_VM_INFO64,
                    ptr,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            return unifiedMemoryBytes()
        }
        let pageSize = UInt64(vm_kernel_page_size)
        // Treat free + inactive + speculative as "available". macOS will
        // happily reclaim inactive pages when llama.cpp asks for a big
        // contiguous allocation.
        let freeBytes = (UInt64(stats.free_count)
            + UInt64(stats.inactive_count)
            + UInt64(stats.speculative_count)) * pageSize
        // Clamp to physical memory just in case the kernel returns
        // something nonsensical (it sometimes does on virtualised hosts).
        return min(freeBytes, unifiedMemoryBytes())
    }

    // MARK: - Internal probe

    private struct Probe {
        let umaBytes: UInt64
        let maxContextLength: Int
    }

    private static func runProbe(
        modelUrl: URL,
        ctxSize: Int
    ) async throws -> Probe {
        let output = try await runParser(arguments: [
            "--path", modelUrl.path,
            "--ctx-size", "\(ctxSize)",
            "--gpu-layers", "99",
            "--flash-attention",
            "--skip-tokenizer",
            "--skip-metadata",
            "--no-mmap",
            "--json"
        ])
        return try parseProbe(json: output, requestedCtx: ctxSize)
    }

    private static func runParser(arguments: [String]) async throws -> Data {
        guard let executable = parserBinaryURL() else {
            throw GGUFEstimatorError.binaryNotFound
        }
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            if process.terminationStatus != 0 {
                let message = String(data: stderrData, encoding: .utf8) ?? ""
                Self.logger.error(
                    "gguf-parser exited \(process.terminationStatus, privacy: .public): \(message, privacy: .public)"
                )
                throw GGUFEstimatorError.nonZeroExit(process.terminationStatus, message)
            }
            return stdoutData
        }.value
    }

    private static func parserBinaryURL() -> URL? {
        // We expect `gguf-parser` to be bundled into the app's
        // PrivateFrameworks directory at build time, same as
        // `llama-server`. Fall back to a top-level Auxiliary Executable
        // location for development builds.
        if let url = Bundle.main.privateFrameworksURL?
            .appendingPathComponent("gguf-parser"),
           FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        if let url = Bundle.main.url(forAuxiliaryExecutable: "gguf-parser") {
            return url
        }
        return nil
    }

    // MARK: - JSON parsing

    private static func parseProbe(
        json data: Data,
        requestedCtx: Int
    ) throws -> Probe {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GGUFEstimatorError.malformedOutput("root is not an object")
        }
        // Trained max ctx lives in `architecture.maximumContextLength`.
        let maxCtx: Int
        if let arch = root["architecture"] as? [String: Any],
           let value = arch["maximumContextLength"] as? Int {
            maxCtx = value
        } else if let arch = root["architecture"] as? [String: Any],
                  let value = arch["maximumContextLength"] as? NSNumber {
            maxCtx = value.intValue
        } else {
            maxCtx = requestedCtx
        }
        // Estimate path: `estimate.items[0]`. UMA memory equals the
        // sum of the per-device UMA + the RAM portion (input layers).
        // gguf-parser-go exposes these as `ram.uma` and
        // `vrams[0].uma` (in bytes).
        guard let estimate = root["estimate"] as? [String: Any] else {
            throw GGUFEstimatorError.malformedOutput("missing estimate")
        }
        let items: [[String: Any]]
        if let array = estimate["items"] as? [[String: Any]] {
            items = array
        } else if estimate["ram"] != nil {
            // Some versions output a single item rather than a list.
            items = [estimate]
        } else {
            throw GGUFEstimatorError.malformedOutput("missing estimate.items")
        }
        guard let item = items.first else {
            throw GGUFEstimatorError.malformedOutput("estimate.items empty")
        }
        let ramBytes = umaBytes(in: item["ram"]) ?? 0
        var vramBytes: UInt64 = 0
        if let vrams = item["vrams"] as? [[String: Any]] {
            for vram in vrams {
                vramBytes &+= umaBytes(in: vram) ?? 0
            }
        }
        return Probe(
            umaBytes: ramBytes + vramBytes,
            maxContextLength: maxCtx
        )
    }

    private static func umaBytes(in section: Any?) -> UInt64? {
        guard let dict = section as? [String: Any] else { return nil }
        // Prefer UMA fields when present (Apple Silicon path). Fall back
        // to `nonuma` for non-Apple hosts.
        for key in ["uma", "nonuma"] {
            if let value = dict[key] as? UInt64 { return value }
            if let value = dict[key] as? Int { return UInt64(max(0, value)) }
            if let value = dict[key] as? NSNumber { return value.uint64Value }
        }
        return nil
    }

    // MARK: - Linear fit

    /// Solve for the largest context that fits in `usableBytes` given a
    /// straight line through `(smallCtx, smallBytes)` and
    /// `(largeCtx, largeBytes)`. Clamps the result to `[0, trainedMax]`
    /// and rounds down to a multiple of 512.
    private static func solveSafeMax(
        smallCtx: Int,
        smallBytes: UInt64,
        largeCtx: Int,
        largeBytes: UInt64,
        trainedMax: Int,
        usableBytes: UInt64
    ) -> Int {
        let dxRaw = largeCtx - smallCtx
        // If both probes are at the same point or memory shrinks with
        // context (shouldn't happen, but be defensive), just trust the
        // bigger probe.
        if dxRaw <= 0 || largeBytes <= smallBytes {
            return largeBytes <= usableBytes ? trainedMax : 0
        }
        let slope = Double(largeBytes - smallBytes) / Double(dxRaw)
        let base = Double(smallBytes) - slope * Double(smallCtx)
        let solved = (Double(usableBytes) - base) / slope
        var ctx = Int(solved.rounded(.down))
        ctx = min(ctx, trainedMax)
        ctx = max(0, ctx)
        // Snap to 512 for a clean number on the slider.
        ctx = (ctx / 512) * 512
        return ctx
    }

    private static func interpolate(
        ctx: Int,
        smallCtx: Int,
        smallBytes: UInt64,
        largeCtx: Int,
        largeBytes: UInt64
    ) -> UInt64 {
        let dxRaw = largeCtx - smallCtx
        if dxRaw <= 0 { return smallBytes }
        let slope = Double(Int64(largeBytes) - Int64(smallBytes)) / Double(dxRaw)
        let base = Double(smallBytes) - slope * Double(smallCtx)
        let value = base + slope * Double(ctx)
        return value < 0 ? 0 : UInt64(value)
    }
}
