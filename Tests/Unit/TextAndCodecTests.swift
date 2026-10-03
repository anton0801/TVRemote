import CryptoKit
import Security
import XCTest
@testable import TVRemoteScreenMirroring

final class TextDiffTests: XCTestCase {
    func testAppendOnly() {
        XCTAssertEqual(TextDiff.appendDeleteOperations(from: "Stran", to: "Stranger"), [.append("ger")])
    }

    func testNoChange() {
        XCTAssertEqual(TextDiff.appendDeleteOperations(from: "abc", to: "abc"), [])
    }

    func testBackspaceOfSimpleCharacterDeletesOne() {
        XCTAssertEqual(TextDiff.appendDeleteOperations(from: "Netflix", to: "Netfli"), [.deleteBackward(count: 1)])
    }

    func testMidStringEditUsesReplace() {
        XCTAssertEqual(TextDiff.appendDeleteOperations(from: "cat", to: "cut"), [.deleteBackward(count: 2), .append("ut")])
        XCTAssertEqual(TextDiff.appendDeleteOperations(from: "hello world", to: "help"), [.deleteBackward(count: 8), .append("p")])
    }

    func testEmojiDeletionFallsBackToReplace() {
        // An emoji is 2 UTF-16 units; "count" would be ambiguous for the TV, so replace.
        XCTAssertEqual(TextDiff.appendDeleteOperations(from: "hi 👍", to: "hi "), [.replaceAll("hi ")])
    }

    func testDecomposedAccentFallsBackToReplace() {
        let decomposed = "cafe\u{301}" // é as e + combining accent: one Character, two scalars
        XCTAssertEqual(TextDiff.appendDeleteOperations(from: decomposed, to: "caf"), [.replaceAll("caf")])
    }

    /// Spec §9: EN, ES, RU, DE, FR samples are appended intact, grapheme by grapheme.
    func testFiveLanguagesAppendIntact() {
        let samples = ["Stranger Things", "Mañana, ¿qué?", "Мастер и Маргарита", "Straße über Äpfel", "Ça c’est l’été", "line1\nline2", "it's"]
        for sample in samples {
            var sent = ""
            var received = ""
            for character in sample {
                let next = sent + String(character)
                for operation in TextDiff.appendDeleteOperations(from: sent, to: next) {
                    guard case .append(let text) = operation else { return XCTFail("Unexpected \(operation)") }
                    received += text
                }
                sent = next
            }
            XCTAssertEqual(received, sample)
        }
    }

    func testCyrillicBackspace() {
        XCTAssertEqual(TextDiff.appendDeleteOperations(from: "Привет", to: "Приве"), [.deleteBackward(count: 1)])
    }
}

final class ProtobufTests: XCTestCase {
    func testVarintRoundTrip() throws {
        for value: UInt64 in [0, 1, 127, 128, 300, 16_384, 1 << 35] {
            var data = Data()
            Protobuf.appendVarint(value, to: &data)
            var index = data.startIndex
            XCTAssertEqual(try Protobuf.readVarint(data, &index), value)
        }
    }

    func testNestedMessageRoundTrip() throws {
        let encoded = Protobuf.encode { writer in
            writer.message(10) { key in
                key.varint(1, 19)
                key.varint(2, 3)
            }
            writer.string(3, "Привет")
        }
        let message = try Protobuf.Message(encoded)
        XCTAssertEqual(message.message(10)?.int(1), 19)
        XCTAssertEqual(message.message(10)?.int(2), 3)
        XCTAssertEqual(message.string(3), "Привет")
    }

    func testFrameBufferHandlesSplitAndMultipleFrames() throws {
        let first = Protobuf.frame(Protobuf.encode { $0.varint(1, 5) })
        let big = Protobuf.frame(Protobuf.encode { $0.string(2, String(repeating: "x", count: 300)) }) // varint length > 127
        var buffer = Protobuf.FrameBuffer()
        let stream = first + big
        buffer.append(stream.prefix(3))
        XCTAssertNotNil(try buffer.nextFrame())
        XCTAssertNil(try buffer.nextFrame())
        buffer.append(stream.dropFirst(3))
        let second = try XCTUnwrap(try buffer.nextFrame())
        XCTAssertEqual(try Protobuf.Message(second).string(2)?.count, 300)
    }

    func testUnknownFieldsAreSkipped() throws {
        var data = Protobuf.encode { $0.varint(1, 7) }
        data.append(contentsOf: [0x15, 1, 2, 3, 4]) // field 2, wire type 5 (fixed32)
        XCTAssertEqual(try Protobuf.Message(data).int(1), 7)
    }
}

final class AndroidTVPairingTests: XCTestCase {
    func testExponentEncodingMatchesReference() {
        XCTAssertEqual(AndroidTVPairingProtocol.exponentBytes(Data([0x01, 0x00, 0x01])), Data([0x01, 0x00, 0x01]))
        XCTAssertEqual(AndroidTVPairingProtocol.exponentBytes(Data([0x00, 0x01, 0x00, 0x01])), Data([0x01, 0x00, 0x01]))
    }

    func testPINCheckAcceptsMatchingChecksum() {
        var clientBytes = [UInt8](repeating: 0, count: 256)
        var serverBytes = [UInt8](repeating: 0, count: 256)
        for index in 0..<256 {
            clientBytes[index] = UInt8(truncatingIfNeeded: index * 7 + 131)
            serverBytes[index] = UInt8(truncatingIfNeeded: index * 13 + 17)
        }
        clientBytes[0] |= 0x80 // 2048-bit moduli have the top bit set
        serverBytes[0] |= 0x80
        let clientN = Data(clientBytes)
        let serverN = Data(serverBytes)
        let e = Data([0x01, 0x00, 0x01])
        let lastTwo = Data([0xAB, 0xCD])
        var hasher = SHA256()
        hasher.update(data: clientN); hasher.update(data: e); hasher.update(data: serverN); hasher.update(data: e); hasher.update(data: lastTwo)
        let digest = Data(hasher.finalize())
        let pin = String(format: "%02X", digest[0]) + "ABCD"
        XCTAssertEqual(AndroidTVPairingProtocol.checkPIN(pin, clientModulus: clientN, clientExponent: e, serverModulus: serverN, serverExponent: e), .valid(secret: digest))
        let wrongFirst = String(format: "%02X", digest[0] ^ 0xFF) + "ABCD"
        XCTAssertEqual(AndroidTVPairingProtocol.checkPIN(wrongFirst, clientModulus: clientN, clientExponent: e, serverModulus: serverN, serverExponent: e), .checksumMismatch)
        XCTAssertEqual(AndroidTVPairingProtocol.checkPIN("12G", clientModulus: clientN, clientExponent: e, serverModulus: serverN, serverExponent: e), .invalidFormat)
    }

    func testPairingMessagesHaveEnvelope() throws {
        let message = try Protobuf.Message(AndroidTVPairingProtocol.pairingRequest(clientName: "iPhone"))
        XCTAssertEqual(message.int(1), 2)
        XCTAssertEqual(message.int(2), 200)
        XCTAssertEqual(message.message(10)?.string(1), "atvremote")
        let configuration = try Protobuf.Message(AndroidTVPairingProtocol.configuration())
        XCTAssertEqual(configuration.message(30)?.message(1)?.int(1), 3) // hexadecimal
        XCTAssertEqual(configuration.message(30)?.message(1)?.int(2), 6)
    }
}

final class DERTests: XCTestCase {
    func testSelfSignedCertificateIsAcceptedBySecurityFramework() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let publicData = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        let der = try ClientIdentityStore.makeSelfSignedCertificate(publicKeyPKCS1: publicData, commonName: "Test") { tbs in
            try XCTUnwrap(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, nil) as Data?)
        }
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        XCTAssertEqual(SecCertificateCopySubjectSummary(certificate) as String?, "Test")
        let components = try XCTUnwrap(certificate.rsaPublicKeyComponents)
        XCTAssertEqual(components.modulus.count, 256)
        XCTAssertEqual(components.exponent, Data([0x01, 0x00, 0x01]))
    }

    func testOIDEncoding() {
        XCTAssertEqual(DER.oid([1, 2, 840, 113549, 1, 1, 11]), Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]))
    }

    func testIntegerSignPadding() {
        XCTAssertEqual(DER.integer(Data([0x80])), Data([0x02, 0x02, 0x00, 0x80]))
        XCTAssertEqual(DER.integer(Data([0x00, 0x00, 0x05])), Data([0x02, 0x01, 0x05]))
    }
}

final class NetworkParsingTests: XCTestCase {
    func testSSDPResponseParsing() {
        let text = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nLOCATION: http://192.168.1.20:9197/dmr\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\nUSN: uuid:abc-123::urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"
        let response = SSDPClient.parse(text, from: "192.168.1.20")
        XCTAssertEqual(response?.location.absoluteString, "http://192.168.1.20:9197/dmr")
        XCTAssertEqual(response?.usn, "uuid:abc-123::urn:schemas-upnp-org:device:MediaRenderer:1")
    }

    func testSSDPRejectsPublicLocation() {
        let text = "HTTP/1.1 200 OK\r\nLOCATION: http://8.8.8.8/desc.xml\r\nST: ssdp:all\r\n\r\n"
        XCTAssertNil(SSDPClient.parse(text, from: "192.168.1.20"), "Never follow a LOCATION outside the LAN")
    }

    func testUPnPDescriptionPicksMediaRenderer() throws {
        let xml = """
        <?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><device>
        <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType><friendlyName>[TV] Living Room</friendlyName>
        <manufacturer>Samsung Electronics</manufacturer><modelName>QE55Q80C</modelName><UDN>uuid:1234-5678</UDN>
        <serviceList><service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/upnp/control/AVTransport1</controlURL></service>
        <service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><controlURL>/upnp/control/ConnectionManager1</controlURL></service></serviceList>
        </device></root>
        """
        let description = try XCTUnwrap(UPnPDescriptionParser.parse(Data(xml.utf8), baseURL: URL(string: "http://192.168.1.20:9197/dmr")!))
        XCTAssertTrue(description.isMediaRenderer)
        XCTAssertEqual(description.udn, "1234-5678")
        XCTAssertEqual(description.service(containing: "AVTransport")?.controlURL.absoluteString, "http://192.168.1.20:9197/upnp/control/AVTransport1")
    }

    func testDIDLMetadataEscapesURL() {
        let metadata = DIDL.metadata(url: URL(string: "http://192.168.1.2:5000/m/abc/photo.jpg?a=1&b=2")!, mimeType: "image/jpeg", title: "A & B", isImage: true)
        XCTAssertTrue(metadata.contains("a=1&amp;b=2"))
        XCTAssertTrue(metadata.contains("A &amp; B"))
        XCTAssertTrue(metadata.contains("object.item.imageItem.photo"))
    }

    func testUPnPTimeParsing() {
        XCTAssertEqual(MediaRendererController.parseTime("0:01:05"), 65)
        XCTAssertEqual(MediaRendererController.parseTime("1:00:00.500"), 3600)
        XCTAssertNil(MediaRendererController.parseTime("NOT_IMPLEMENTED"))
        XCTAssertEqual(MediaRendererController.timeString(3725), "1:02:05")
    }

    func testSamsungDeviceInfoParsing() throws {
        let json: [String: Any] = [
            "device": ["duid": "uuid:ABC-123", "name": "[TV] Samsung Q80", "modelName": "QE55Q80C", "OS": "Tizen",
                       "TokenAuthSupport": "true", "wifiMac": "aa:bb:cc:dd:ee:ff", "PowerState": "on"],
            "id": "uuid:ABC-123", "name": "[TV] Samsung Q80",
        ]
        let info = try SamsungDeviceInfo.parse(json)
        XCTAssertEqual(info.id, "ABC-123")
        XCTAssertEqual(info.name, "Samsung Q80")
        XCTAssertEqual(info.tokenAuthSupport, true)
        XCTAssertEqual(info.powerState, "on")
    }

    func testStableDeviceIDIgnoresCase() {
        XCTAssertEqual(TVDeviceID(platform: .samsungTizen, uniqueID: "ABC"), TVDeviceID(platform: .samsungTizen, uniqueID: "abc"))
        XCTAssertNotEqual(TVDeviceID(platform: .samsungTizen, uniqueID: "abc"), TVDeviceID(platform: .lgWebOS, uniqueID: "abc"))
    }

    func testCertificatePinningDecisions() {
        XCTAssertEqual(CertificatePinning.evaluate(host: "192.168.1.5", presentedFingerprint: "aa", pinned: nil, allowFirstUse: true), .accept(fingerprint: "aa"))
        XCTAssertEqual(CertificatePinning.evaluate(host: "192.168.1.5", presentedFingerprint: "aa", pinned: nil, allowFirstUse: false), .reject)
        XCTAssertEqual(CertificatePinning.evaluate(host: "8.8.8.8", presentedFingerprint: "aa", pinned: nil, allowFirstUse: true), .reject)
        XCTAssertEqual(CertificatePinning.evaluate(host: "192.168.1.5", presentedFingerprint: "bb", pinned: "aa", allowFirstUse: true), .reject)
        XCTAssertEqual(CertificatePinning.evaluate(host: "192.168.1.5", presentedFingerprint: "aa", pinned: "aa", allowFirstUse: false), .accept(fingerprint: "aa"))
    }

    func testWakeOnLANPacket() throws {
        let packet = try XCTUnwrap(WakeOnLAN.magicPacket(mac: "AA:BB:CC:DD:EE:FF"))
        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual(packet.prefix(6), Data(repeating: 0xFF, count: 6))
        XCTAssertEqual(packet[6..<12], Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]))
        XCTAssertNil(WakeOnLAN.magicPacket(mac: "not-a-mac"))
    }

    func testSubnetScanIsBoundedAndSkipsSelf() {
        let info = LocalNetworkInfo(address: "10.0.5.23", netmask: "255.255.0.0", interfaceName: "en0")
        let hosts = info.scanCandidates()
        XCTAssertEqual(hosts.count, 253)
        XCTAssertFalse(hosts.contains("10.0.5.23"))
        XCTAssertTrue(hosts.allSatisfy { $0.hasPrefix("10.0.5.") })
    }

    func testLGManifestIsUnsigned() {
        XCTAssertNil(LGManifest.unsigned["signatures"], "webOS 26 rejects the old signed test manifest")
        XCTAssertTrue(LGManifest.permissions.contains("CONTROL_INPUT_TEXT"))
    }
}
