import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Wakes a sleeping NAS with a Wake-on-LAN "magic packet": six 0xFF bytes,
/// then the NAS's MAC address 16 times, sent over UDP to port 9.
///
/// It's sent as a broadcast on the local network and also straight to the
/// NAS's last known address. On iPhone and iPad, broadcasts need Apple's
/// multicast entitlement; the direct copy works without it as long as the
/// network still knows where the NAS is. It only works on the home network.
public enum WakeOnLAN {
    /// "00:11:32:aa:bb:cc", "00-11-32-AA-BB-CC" or "001132AABBCC" → 6 bytes.
    public static func parseMAC(_ text: String) -> [UInt8]? {
        let hex = text.filter { $0.isHexDigit }
        let separators = text.filter { !$0.isHexDigit && !$0.isWhitespace }
        guard hex.count == 12, separators.allSatisfy({ $0 == ":" || $0 == "-" || $0 == "." }) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// "00:11:32:AA:BB:CC", for showing and saving.
    public static func format(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    public static func packet(for mac: [UInt8]) -> [UInt8] {
        [UInt8](repeating: 0xFF, count: 6) + (0..<16).flatMap { _ in mac }
    }

    /// Sends the packet to the broadcast address and to each of `hosts`
    /// (IP addresses). Returns true if at least one copy was sent.
    @discardableResult
    public static func send(mac: [UInt8], to hosts: [String] = []) -> Bool {
        let bytes = packet(for: mac)
        var sent = false
        for host in ["255.255.255.255"] + hosts {
            if sendUDP(bytes, to: host, port: 9) { sent = true }
        }
        return sent
    }

    private static func sendUDP(_ bytes: [UInt8], to host: String, port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return false }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bytes.withUnsafeBytes { buffer in
                    sendto(fd, buffer.baseAddress, buffer.count, 0, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return result == bytes.count
    }
}
