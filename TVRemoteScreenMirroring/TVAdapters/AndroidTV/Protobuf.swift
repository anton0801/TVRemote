import Foundation

/// Minimal protocol-buffers wire codec for the handful of Android TV Remote v2 messages.
/// Supports varint (wire type 0) and length-delimited (wire type 2) fields, which is all the
/// protocol uses. Unknown fields are skipped when decoding.
enum Protobuf {
    enum DecodeError: Error { case truncated, unsupportedWireType(UInt8) }

    // MARK: Encoding

    struct Writer {
        private(set) var data = Data()

        mutating func varint(_ field: Int, _ value: UInt64) {
            tag(field, wireType: 0)
            Protobuf.appendVarint(value, to: &data)
        }

        mutating func varint(_ field: Int, _ value: Int) {
            varint(field, UInt64(bitPattern: Int64(value)))
        }

        mutating func bool(_ field: Int, _ value: Bool) {
            varint(field, UInt64(value ? 1 : 0))
        }

        mutating func bytes(_ field: Int, _ value: Data) {
            tag(field, wireType: 2)
            Protobuf.appendVarint(UInt64(value.count), to: &data)
            data.append(value)
        }

        mutating func string(_ field: Int, _ value: String) {
            bytes(field, Data(value.utf8))
        }

        mutating func message(_ field: Int, _ build: (inout Writer) -> Void) {
            var nested = Writer()
            build(&nested)
            bytes(field, nested.data)
        }

        private mutating func tag(_ field: Int, wireType: UInt8) {
            Protobuf.appendVarint(UInt64(field << 3) | UInt64(wireType), to: &data)
        }
    }

    static func encode(_ build: (inout Writer) -> Void) -> Data {
        var writer = Writer()
        build(&writer)
        return writer.data
    }

    static func appendVarint(_ value: UInt64, to data: inout Data) {
        var v = value
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            data.append(byte)
        } while v != 0
    }

    /// Length-prefixed frame (varint length) as used on the wire by both pairing and remote channels.
    static func frame(_ message: Data) -> Data {
        var out = Data()
        appendVarint(UInt64(message.count), to: &out)
        out.append(message)
        return out
    }

    // MARK: Decoding

    /// Decoded message: field number → list of values (repeated fields keep order).
    struct Message: Sendable {
        enum Value: Sendable {
            case varint(UInt64)
            case bytes(Data)
        }

        private(set) var fields: [Int: [Value]] = [:]

        init(_ data: Data) throws {
            var index = data.startIndex
            while index < data.endIndex {
                let key = try Protobuf.readVarint(data, &index)
                let field = Int(key >> 3)
                let wireType = UInt8(key & 0x7)
                switch wireType {
                case 0:
                    fields[field, default: []].append(.varint(try Protobuf.readVarint(data, &index)))
                case 1:
                    guard data.distance(from: index, to: data.endIndex) >= 8 else { throw DecodeError.truncated }
                    index = data.index(index, offsetBy: 8)
                case 2:
                    guard let length = Int(exactly: try Protobuf.readVarint(data, &index)) else { throw DecodeError.truncated }
                    guard length >= 0, data.distance(from: index, to: data.endIndex) >= length else { throw DecodeError.truncated }
                    let end = data.index(index, offsetBy: length)
                    fields[field, default: []].append(.bytes(Data(data[index..<end])))
                    index = end
                case 5:
                    guard data.distance(from: index, to: data.endIndex) >= 4 else { throw DecodeError.truncated }
                    index = data.index(index, offsetBy: 4)
                default:
                    throw DecodeError.unsupportedWireType(wireType)
                }
            }
        }

        func has(_ field: Int) -> Bool { fields[field]?.isEmpty == false }

        func uint(_ field: Int) -> UInt64? {
            if case .varint(let v)? = fields[field]?.last { return v }
            return nil
        }

        func int(_ field: Int) -> Int? {
            uint(field).map { Int(Int64(bitPattern: $0)) }
        }

        func bool(_ field: Int) -> Bool? {
            uint(field).map { $0 != 0 }
        }

        func bytes(_ field: Int) -> Data? {
            if case .bytes(let d)? = fields[field]?.last { return d }
            return nil
        }

        func string(_ field: Int) -> String? {
            bytes(field).flatMap { String(data: $0, encoding: .utf8) }
        }

        func message(_ field: Int) -> Message? {
            bytes(field).flatMap { try? Message($0) }
        }
    }

    static func readVarint(_ data: Data, _ index: inout Data.Index) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.endIndex {
            let byte = data[index]
            index = data.index(after: index)
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw DecodeError.truncated }
        }
        throw DecodeError.truncated
    }

    /// Incremental frame parser for a TCP byte stream.
    struct FrameBuffer {
        private var buffer = Data()

        mutating func append(_ data: Data) { buffer.append(data) }

        /// Returns the next complete message payload, if available.
        mutating func nextFrame() throws -> Data? {
            var index = buffer.startIndex
            let length: UInt64
            do {
                length = try Protobuf.readVarint(buffer, &index)
            } catch {
                return nil // not enough bytes for the length prefix yet
            }
            guard length < 1_000_000 else { throw DecodeError.truncated }
            guard buffer.distance(from: index, to: buffer.endIndex) >= Int(length) else { return nil }
            let end = buffer.index(index, offsetBy: Int(length))
            let payload = Data(buffer[index..<end])
            buffer = Data(buffer[end...])
            return payload
        }
    }
}
