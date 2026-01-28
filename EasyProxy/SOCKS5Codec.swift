import NIOCore

// MARK: - SOCKS5 Constants

enum SOCKS5 {
    static let version: UInt8 = 0x05

    enum AuthMethod: UInt8 {
        case noAuth = 0x00
        case usernamePassword = 0x02
        case noAcceptable = 0xFF
    }

    enum Command: UInt8 {
        case connect = 0x01
        case bind = 0x02
        case udpAssociate = 0x03
    }

    enum AddressType: UInt8 {
        case ipv4 = 0x01
        case domain = 0x03
        case ipv6 = 0x04
    }

    enum ReplyStatus: UInt8 {
        case succeeded = 0x00
        case generalFailure = 0x01
        case connectionNotAllowed = 0x02
        case networkUnreachable = 0x03
        case hostUnreachable = 0x04
        case connectionRefused = 0x05
        case ttlExpired = 0x06
        case commandNotSupported = 0x07
        case addressTypeNotSupported = 0x08
    }
}

// MARK: - SOCKS5 Address

/// Represents a SOCKS5 address (IPv4, IPv6, or domain name).
struct SOCKS5Address {
    let type: SOCKS5.AddressType
    let host: String
    let port: UInt16

    /// Raw bytes for the address portion (without port).
    var rawAddressBytes: [UInt8] {
        switch type {
        case .ipv4:
            return host.split(separator: ".").compactMap { UInt8($0) }
        case .ipv6:
            return parseIPv6(host)
        case .domain:
            let domainBytes = Array(host.utf8)
            return [UInt8(domainBytes.count)] + domainBytes
        }
    }

    private func parseIPv6(_ str: String) -> [UInt8] {
        // Simplified IPv6 parsing — expand :: and convert to 16 bytes
        var groups = str.split(separator: ":", omittingEmptySubsequences: false).map { String($0) }

        // Handle :: expansion
        if let emptyIdx = groups.firstIndex(of: "") {
            // Count non-empty groups
            let nonEmpty = groups.filter { !$0.isEmpty }
            let missing = 8 - nonEmpty.count
            var expanded = [String]()
            for (i, g) in groups.enumerated() {
                if i == emptyIdx {
                    for _ in 0..<missing {
                        expanded.append("0")
                    }
                } else if !g.isEmpty {
                    expanded.append(g)
                }
            }
            groups = expanded
        }

        var bytes = [UInt8]()
        for group in groups.prefix(8) {
            let val = UInt16(group, radix: 16) ?? 0
            bytes.append(UInt8(val >> 8))
            bytes.append(UInt8(val & 0xFF))
        }
        // Pad to 16 bytes
        while bytes.count < 16 {
            bytes.append(0)
        }
        return bytes
    }
}

// MARK: - Greeting Message

struct SOCKS5GreetingRequest {
    let methods: [UInt8]

    static func decode(from buffer: inout ByteBuffer) -> SOCKS5GreetingRequest? {
        guard let version = buffer.readInteger(as: UInt8.self),
              version == SOCKS5.version,
              let nMethods = buffer.readInteger(as: UInt8.self),
              nMethods > 0,
              let methods = buffer.readBytes(length: Int(nMethods))
        else {
            return nil
        }
        return SOCKS5GreetingRequest(methods: methods)
    }
}

struct SOCKS5GreetingResponse {
    let method: SOCKS5.AuthMethod

    func encode(into buffer: inout ByteBuffer) {
        buffer.writeInteger(SOCKS5.version)
        buffer.writeInteger(method.rawValue)
    }
}

// MARK: - Command Request

struct SOCKS5CommandRequest {
    let command: SOCKS5.Command
    let address: SOCKS5Address

    static func decode(from buffer: inout ByteBuffer) -> SOCKS5CommandRequest? {
        guard let version = buffer.readInteger(as: UInt8.self),
              version == SOCKS5.version,
              let cmdByte = buffer.readInteger(as: UInt8.self),
              let command = SOCKS5.Command(rawValue: cmdByte),
              let _ = buffer.readInteger(as: UInt8.self), // RSV
              let address = decodeAddress(from: &buffer)
        else {
            return nil
        }
        return SOCKS5CommandRequest(command: command, address: address)
    }
}

// MARK: - Command Reply

struct SOCKS5CommandReply {
    let status: SOCKS5.ReplyStatus
    let boundAddress: SOCKS5Address

    func encode(into buffer: inout ByteBuffer) {
        buffer.writeInteger(SOCKS5.version)
        buffer.writeInteger(status.rawValue)
        buffer.writeInteger(UInt8(0x00)) // RSV
        buffer.writeInteger(boundAddress.type.rawValue)
        buffer.writeBytes(boundAddress.rawAddressBytes)
        buffer.writeInteger(boundAddress.port, endianness: .big)
    }
}

// MARK: - UDP Header

/// SOCKS5 UDP relay header (RFC 1928 §7).
///
/// ```
/// +----+------+------+----------+----------+----------+
/// |RSV | FRAG | ATYP | DST.ADDR | DST.PORT |   DATA   |
/// +----+------+------+----------+----------+----------+
/// | 2  |  1   |  1   | Variable |    2     | Variable |
/// +----+------+------+----------+----------+----------+
/// ```
struct SOCKS5UDPHeader {
    let frag: UInt8
    let address: SOCKS5Address

    static func decode(from buffer: inout ByteBuffer) -> (header: SOCKS5UDPHeader, data: ByteBuffer)? {
        guard let rsv = buffer.readInteger(as: UInt16.self), // 2 bytes RSV
              rsv == 0,
              let frag = buffer.readInteger(as: UInt8.self),
              let address = decodeAddress(from: &buffer)
        else {
            return nil
        }
        let data = buffer.readSlice(length: buffer.readableBytes) ?? ByteBuffer()
        return (SOCKS5UDPHeader(frag: frag, address: address), data)
    }

    func encode(into buffer: inout ByteBuffer) {
        buffer.writeInteger(UInt16(0)) // RSV
        buffer.writeInteger(frag)
        buffer.writeInteger(address.type.rawValue)
        buffer.writeBytes(address.rawAddressBytes)
        buffer.writeInteger(address.port, endianness: .big)
    }
}

// MARK: - Shared Address Decoding

private func decodeAddress(from buffer: inout ByteBuffer) -> SOCKS5Address? {
    guard let typeByte = buffer.readInteger(as: UInt8.self),
          let addressType = SOCKS5.AddressType(rawValue: typeByte)
    else {
        return nil
    }

    let host: String
    switch addressType {
    case .ipv4:
        guard let bytes = buffer.readBytes(length: 4) else { return nil }
        host = bytes.map { String($0) }.joined(separator: ".")
    case .domain:
        guard let length = buffer.readInteger(as: UInt8.self),
              let domainBytes = buffer.readBytes(length: Int(length))
        else { return nil }
        host = String(bytes: domainBytes, encoding: .utf8) ?? ""
    case .ipv6:
        guard let bytes = buffer.readBytes(length: 16) else { return nil }
        var groups = [String]()
        for i in stride(from: 0, to: 16, by: 2) {
            let val = (UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1])
            groups.append(String(val, radix: 16))
        }
        host = groups.joined(separator: ":")
    }

    guard let port = buffer.readInteger(endianness: .big, as: UInt16.self) else { return nil }
    return SOCKS5Address(type: addressType, host: host, port: port)
}
