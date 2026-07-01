//
//  ZstdDecoder.swift
//  Arc Viewer
//
//  Runtime zstd (Zstandard) decompression. Apple's Compression framework does
//  not include zstd, so we resolve libzstd dynamically via dlopen/dlsym. This
//  keeps the project free of extra link flags / bridging headers and degrades
//  gracefully (returns nil) when no libzstd is available on the host.
//
//  libzstd is searched for in the app bundle first (so it can be embedded for
//  distribution), then in common system / Homebrew locations.
//

import Foundation

// zstd streaming I/O buffers — must match the C ABI layout
// (pointer, size_t, size_t) from zstd.h.
nonisolated private struct ZSTDInBuffer { var src: UnsafeRawPointer?; var size: Int; var pos: Int }
nonisolated private struct ZSTDOutBuffer { var dst: UnsafeMutableRawPointer?; var size: Int; var pos: Int }

private typealias FnCreateDStream = @convention(c) () -> OpaquePointer?
private typealias FnFreeDStream = @convention(c) (OpaquePointer?) -> Int
private typealias FnInitDStream = @convention(c) (OpaquePointer?) -> Int
private typealias FnDecompressStream = @convention(c)
    (OpaquePointer?, UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int
private typealias FnIsError = @convention(c) (Int) -> UInt32
private typealias FnDStreamOutSize = @convention(c) () -> Int

/// Lazily-resolved libzstd decoder. Thread-safe to construct once and reuse.
nonisolated final class ZstdDecoder {
    static let shared = ZstdDecoder()

    private let handle: UnsafeMutableRawPointer?
    private let createDStream: FnCreateDStream?
    private let freeDStream: FnFreeDStream?
    private let initDStream: FnInitDStream?
    private let decompressStream: FnDecompressStream?
    private let isError: FnIsError?
    private let dStreamOutSize: FnDStreamOutSize?

    /// Whether a usable libzstd was found.
    var isAvailable: Bool { decompressStream != nil && createDStream != nil }

    private init() {
        var opened: UnsafeMutableRawPointer? = nil
        for path in ZstdDecoder.candidatePaths() {
            if let h = dlopen(path, RTLD_NOW) { opened = h; break }
        }
        handle = opened

        func sym<T>(_ name: String, as type: T.Type) -> T? {
            guard let opened, let p = dlsym(opened, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }

        createDStream = sym("ZSTD_createDStream", as: FnCreateDStream.self)
        freeDStream = sym("ZSTD_freeDStream", as: FnFreeDStream.self)
        initDStream = sym("ZSTD_initDStream", as: FnInitDStream.self)
        decompressStream = sym("ZSTD_decompressStream", as: FnDecompressStream.self)
        isError = sym("ZSTD_isError", as: FnIsError.self)
        dStreamOutSize = sym("ZSTD_DStreamOutSize", as: FnDStreamOutSize.self)
    }

    private static func candidatePaths() -> [String] {
        var paths: [String] = []
        // Embedded copy (Frameworks dir or app resources), for a self-contained build.
        if let frameworks = Bundle.main.privateFrameworksPath {
            paths.append(frameworks + "/libzstd.1.dylib")
            paths.append(frameworks + "/libzstd.dylib")
        }
        if let resource = Bundle.main.resourcePath {
            paths.append(resource + "/libzstd.1.dylib")
        }
        // dyld shared cache / standard names, then Homebrew & /usr/local.
        paths += [
            "libzstd.1.dylib",
            "/usr/lib/libzstd.1.dylib",
            "/opt/homebrew/lib/libzstd.1.dylib",
            "/opt/homebrew/lib/libzstd.dylib",
            "/usr/local/lib/libzstd.1.dylib",
            "/usr/local/lib/libzstd.dylib",
        ]
        return paths
    }

    /// Decompresses a zstd stream (one or more frames). Returns nil if libzstd
    /// is unavailable or the data could not be decoded.
    func decompress(_ data: Data) -> Data? {
        guard isAvailable,
              let createDStream, let initDStream, let decompressStream,
              let isError, let freeDStream
        else { return nil }
        guard !data.isEmpty else { return Data() }

        guard let ds = createDStream() else { return nil }
        defer { _ = freeDStream(ds) }
        if isError(initDStream(ds)) != 0 { return nil }

        let outChunk = max(dStreamOutSize?() ?? (128 * 1024), 4096)
        let outBuffer = UnsafeMutableRawPointer.allocate(byteCount: outChunk, alignment: 16)
        defer { outBuffer.deallocate() }

        let src = [UInt8](data)
        return src.withUnsafeBufferPointer { srcBuf -> Data? in
            guard let srcBase = srcBuf.baseAddress else { return nil }
            var result = Data()
            var inBuf = ZSTDInBuffer(src: UnsafeRawPointer(srcBase), size: src.count, pos: 0)

            while true {
                var outBuf = ZSTDOutBuffer(dst: outBuffer, size: outChunk, pos: 0)
                let ret = withUnsafeMutablePointer(to: &outBuf) { outP in
                    withUnsafeMutablePointer(to: &inBuf) { inP in
                        decompressStream(ds, UnsafeMutableRawPointer(outP), UnsafeMutableRawPointer(inP))
                    }
                }
                if isError(ret) != 0 { return result.isEmpty ? nil : result }
                if outBuf.pos > 0 {
                    result.append(outBuffer.assumingMemoryBound(to: UInt8.self), count: outBuf.pos)
                }
                if ret == 0 {
                    // Current frame finished.
                    if inBuf.pos >= inBuf.size { break }       // all input consumed
                    if isError(initDStream(ds)) != 0 { break } // re-init for the next frame
                    continue
                }
                // ret > 0: more work expected. Bail if there's nothing left to feed
                // and nothing was produced (truncated/stuck input).
                if inBuf.pos >= inBuf.size && outBuf.pos == 0 { break }
            }
            return result
        }
    }
}
