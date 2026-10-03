import CryptoKit
import Foundation

/// Android TV Remote v2 pairing ("polo") on TCP 6467 over mutual TLS.
/// Message layout per androidtvremote2 `polo.proto`; see COMPATIBILITY.md for sources.
enum AndroidTVPairingProtocol {
    static let port: UInt16 = 6467
    static let protocolVersion = 2
    static let statusOK = 200
    static let statusBadSecret = 402

    enum Field {
        static let protocolVersion = 1
        static let status = 2
        static let pairingRequest = 10
        static let pairingRequestAck = 11
        static let options = 20
        static let configuration = 30
        static let configurationAck = 31
        static let secret = 40
        static let secretAck = 41
    }

    static let hexadecimalEncoding = 3
    static let roleInput = 1
    static let symbolLength = 6

    static func envelope(_ build: (inout Protobuf.Writer) -> Void) -> Data {
        Protobuf.encode { writer in
            writer.varint(Field.protocolVersion, protocolVersion)
            writer.varint(Field.status, statusOK)
            build(&writer)
        }
    }

    static func pairingRequest(clientName: String) -> Data {
        envelope { writer in
            writer.message(Field.pairingRequest) { request in
                request.string(1, "atvremote")
                request.string(2, clientName)
            }
        }
    }

    static func options() -> Data {
        envelope { writer in
            writer.message(Field.options) { options in
                options.message(1) { encoding in
                    encoding.varint(1, hexadecimalEncoding)
                    encoding.varint(2, symbolLength)
                }
                options.varint(3, roleInput)
            }
        }
    }

    static func configuration() -> Data {
        envelope { writer in
            writer.message(Field.configuration) { configuration in
                configuration.message(1) { encoding in
                    encoding.varint(1, hexadecimalEncoding)
                    encoding.varint(2, symbolLength)
                }
                configuration.varint(2, roleInput)
            }
        }
    }

    static func secret(_ value: Data) -> Data {
        envelope { writer in
            writer.message(Field.secret) { secret in
                secret.bytes(1, value)
            }
        }
    }

    enum PINCheck: Equatable {
        case invalidFormat
        case checksumMismatch
        case valid(secret: Data)
    }

    /// SHA-256(client modulus ‖ client exponent ‖ server modulus ‖ server exponent ‖ PIN[1...2]).
    /// The first PIN byte must equal the first digest byte, which lets the app reject a
    /// mistyped code locally before contacting the TV.
    static func checkPIN(_ pin: String, clientModulus: Data, clientExponent: Data, serverModulus: Data, serverExponent: Data) -> PINCheck {
        let cleaned = pin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard cleaned.count == 6, let bytes = Data(hex: cleaned) else { return .invalidFormat }
        var hasher = SHA256()
        hasher.update(data: DER.stripLeadingZeros(clientModulus))
        hasher.update(data: exponentBytes(clientExponent))
        hasher.update(data: DER.stripLeadingZeros(serverModulus))
        hasher.update(data: exponentBytes(serverExponent))
        hasher.update(data: bytes.suffix(2))
        let digest = Data(hasher.finalize())
        guard digest.first == bytes.first else { return .checksumMismatch }
        return .valid(secret: digest)
    }

    /// Python reference: `bytes.fromhex(f"0{e:X}")` — the hex string gets a leading "0",
    /// so 65537 (0x10001) becomes 01 00 01. Equivalent to the minimal big-endian bytes
    /// when the hex digit count is odd.
    static func exponentBytes(_ exponent: Data) -> Data {
        let stripped = DER.stripLeadingZeros(exponent)
        var hex = stripped.map { String(format: "%02X", $0) }.joined()
        while hex.hasPrefix("0") && hex.count > 1 { hex.removeFirst() }
        let padded = "0" + hex
        let normalized = padded.count % 2 == 0 ? padded : "0" + padded
        return Data(hex: normalized) ?? stripped
    }
}

extension Data {
    init?(hex: String) {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let byte = UInt8(String(chars[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
            index += 2
        }
        self.init(bytes)
    }
}

/// Runs the pairing exchange. Returns the server certificate fingerprint to pin.
struct AndroidTVPairingSession {
    let host: String
    let identity: ClientIdentityStore.Identity
    let clientName: String

    func run(interaction: PairingInteraction) async throws -> String {
        let connection = TLSStreamConnection(host: host, port: AndroidTVPairingProtocol.port, identity: identity.identity, pinnedFingerprint: nil, allowFirstUse: true)
        defer { connection.cancel() }
        try await connection.start()
        var reader = FrameReader(connection: connection)

        try await exchange(connection, &reader, AndroidTVPairingProtocol.pairingRequest(clientName: clientName), expect: AndroidTVPairingProtocol.Field.pairingRequestAck)
        try await exchange(connection, &reader, AndroidTVPairingProtocol.options(), expect: AndroidTVPairingProtocol.Field.options)
        try await exchange(connection, &reader, AndroidTVPairingProtocol.configuration(), expect: AndroidTVPairingProtocol.Field.configurationAck)

        guard let serverCertificate = connection.serverCertificate,
              let server = serverCertificate.rsaPublicKeyComponents,
              let client = identity.certificate.rsaPublicKeyComponents
        else { throw AppError.pairingUnsupportedFirmware }

        for attempt in 1...3 {
            let pin = try await interaction.requestPIN(attempt: attempt)
            switch AndroidTVPairingProtocol.checkPIN(pin, clientModulus: client.modulus, clientExponent: client.exponent,
                                                     serverModulus: server.modulus, serverExponent: server.exponent) {
            case .invalidFormat, .checksumMismatch:
                continue // The TV keeps showing the same code; let the user retype it.
            case .valid(let secret):
                try await connection.send(Protobuf.frame(AndroidTVPairingProtocol.secret(secret)))
                let response = try await reader.next()
                let status = response.int(AndroidTVPairingProtocol.Field.status)
                if status == AndroidTVPairingProtocol.statusOK, response.has(AndroidTVPairingProtocol.Field.secretAck) {
                    return CertificatePinning.sha256Fingerprint(of: serverCertificate)
                }
                throw status == AndroidTVPairingProtocol.statusBadSecret ? AppError.pairingWrongPIN : AppError.pairingRejected
            }
        }
        throw AppError.pairingWrongPIN
    }

    private func exchange(_ connection: TLSStreamConnection, _ reader: inout FrameReader, _ message: Data, expect field: Int) async throws {
        try await connection.send(Protobuf.frame(message))
        let response = try await reader.next()
        guard response.int(AndroidTVPairingProtocol.Field.status) == AndroidTVPairingProtocol.statusOK, response.has(field) else {
            throw AppError.pairingRejected
        }
    }
}

/// Reads varint-framed protobuf messages from a TLS stream with a timeout.
struct FrameReader {
    let connection: TLSStreamConnection
    private var buffer = Protobuf.FrameBuffer()
    private var iterator: AsyncStream<Data>.Iterator

    init(connection: TLSStreamConnection) {
        self.connection = connection
        iterator = connection.incoming.makeAsyncIterator()
    }

    mutating func next(timeout: Duration = .seconds(90)) async throws -> Protobuf.Message {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        // A silent TV must not hang pairing: closing the connection ends the stream.
        let watchdog = Task { [connection] in
            try? await Task.sleep(for: timeout)
            connection.cancel()
        }
        defer { watchdog.cancel() }
        while true {
            if let frame = try buffer.nextFrame() { return try Protobuf.Message(frame) }
            guard ContinuousClock.now < deadline else { throw AppError.pairingTimedOut }
            guard let chunk = await iterator.next() else {
                throw ContinuousClock.now >= deadline ? AppError.pairingTimedOut : AppError.connectionLost
            }
            buffer.append(chunk)
        }
    }
}
