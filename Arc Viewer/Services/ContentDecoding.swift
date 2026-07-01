//
//  ContentDecoding.swift
//  Arc Cache Viewer
//
//  Best-effort decompression of cached response bodies, mirroring the
//  content-encoding handling in ccl_chromium_cache's main(): gzip, deflate
//  (raw), and a pass-through for brotli (not available natively).
//

import Foundation
import Compression

nonisolated enum ContentDecoding {
    /// Returns the decompressed body if `contentEncoding` is one we can handle,
    /// otherwise returns the input unchanged.
    static func decode(_ data: Data, contentEncoding: String?) -> Data {
        let encoding = (contentEncoding ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        switch encoding {
        case "gzip", "x-gzip":
            return inflateGzip(data) ?? data
        case "deflate":
            // Try raw DEFLATE first, then zlib-wrapped.
            return inflateRaw(data) ?? inflateZlib(data) ?? data
        case "zstd", "zst":
            return ZstdDecoder.shared.decompress(data) ?? data
        case "br":
            // Brotli, via the Compression framework (COMPRESSION_BROTLI).
            return streamDecode(data, algorithm: COMPRESSION_BROTLI) ?? data
        case "", "identity", "none":
            // No declared encoding (or metadata didn't parse): sniff for an
            // unambiguous compression magic so we still export something usable.
            return sniffAndDecode(data) ?? data
        default:
            return data
        }
    }

    /// Decodes when the body carries a recognisable compression magic but the
    /// content-encoding wasn't available. Only acts on unambiguous signatures.
    private static func sniffAndDecode(_ data: Data) -> Data? {
        let b = [UInt8](data.prefix(4))
        if b.count >= 2, b[0] == 0x1f, b[1] == 0x8b {
            return inflateGzip(data)                          // gzip
        }
        if b.count >= 4, b[0] == 0x28, b[1] == 0xb5, b[2] == 0x2f, b[3] == 0xfd {
            return ZstdDecoder.shared.decompress(data)        // zstd
        }
        return nil
    }

    /// Whether we have a decoder for the given encoding.
    static func canDecode(_ contentEncoding: String?) -> Bool {
        let e = (contentEncoding ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if ["zstd", "zst"].contains(e) { return ZstdDecoder.shared.isAvailable }
        return ["gzip", "x-gzip", "deflate", "br"].contains(e)
    }

    // MARK: - gzip

    private static func inflateGzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 10, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08 else { return nil }
        let flg = bytes[3]
        var idx = 10
        // FEXTRA
        if flg & 0x04 != 0 {
            guard idx + 2 <= bytes.count else { return nil }
            let xlen = Int(bytes[idx]) | (Int(bytes[idx + 1]) << 8)
            idx += 2 + xlen
        }
        // FNAME
        if flg & 0x08 != 0 { while idx < bytes.count && bytes[idx] != 0 { idx += 1 }; idx += 1 }
        // FCOMMENT
        if flg & 0x10 != 0 { while idx < bytes.count && bytes[idx] != 0 { idx += 1 }; idx += 1 }
        // FHCRC
        if flg & 0x02 != 0 { idx += 2 }
        guard idx < bytes.count else { return nil }
        // Drop the 8-byte trailer (CRC32 + ISIZE); the rest is raw DEFLATE.
        let deflateBytes = Array(bytes[idx ..< max(idx, bytes.count - 8)])
        return inflateRaw(Data(deflateBytes))
    }

    // MARK: - zlib-wrapped DEFLATE (RFC 1950)

    private static func inflateZlib(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        // Skip the 2-byte zlib header, then raw inflate.
        return inflateRaw(data.subdata(in: 2 ..< data.count))
    }

    // MARK: - raw DEFLATE (RFC 1951)

    /// Raw DEFLATE inflate via the Compression framework (COMPRESSION_ZLIB
    /// expects header-less DEFLATE).
    private static func inflateRaw(_ data: Data) -> Data? {
        streamDecode(data, algorithm: COMPRESSION_ZLIB)
    }

    // MARK: - Generic Compression-framework streaming decode

    private static func streamDecode(_ data: Data, algorithm: compression_algorithm) -> Data? {
        guard !data.isEmpty else { return nil }
        let bufferSize = max(data.count * 4, 64 * 1024)
        return data.withUnsafeBytes { (rawSrc: UnsafeRawBufferPointer) -> Data? in
            guard let srcBase = rawSrc.bindMemory(to: UInt8.self).baseAddress else { return nil }

            var stream = compression_stream(
                dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
                dst_size: 0,
                src_ptr: srcBase,
                src_size: data.count,
                state: nil)
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else {
                return nil
            }
            defer { compression_stream_destroy(&stream) }

            stream.src_ptr = srcBase
            stream.src_size = data.count

            var output = Data()
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { dst.deallocate() }

            repeat {
                stream.dst_ptr = dst
                stream.dst_size = bufferSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - stream.dst_size
                if produced > 0 { output.append(dst, count: produced) }
                switch status {
                case COMPRESSION_STATUS_OK:
                    continue
                case COMPRESSION_STATUS_END:
                    return output.isEmpty ? nil : output
                default:
                    return output.isEmpty ? nil : output
                }
            } while true
        }
    }
}
