import XCTest
@testable import TetherCore

/// Random requests through the config page's parser, which reads whatever a client on the hotspot
/// sends (#157). Swift has no fuzzer, so this changes real requests at random from a fixed seed: a
/// failure comes back on every run, and the iteration it names gives the input.
final class ConfigPageFuzzTests: XCTestCase {
    /// SplitMix64, so every run makes the same changes. A request that carries the token differs by
    /// it, since the token is new each launch.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func testAnyRequestIsReadWithoutACrash() {
        let seeds = [
            "GET / HTTP/1.1\r\nHost: 172.20.10.1\r\nUser-Agent: Mozilla/5.0\r\nAccept: */*\r\n\r\n",
            "GET \(ConfigPage.downloadPath) HTTP/1.1\r\nHost: [fe80::1%bridge100]:80\r\n\r\n",
            "HEAD /Tether.conf?t=0 HTTP/1.0\r\nhost: 172.20.10.1:80\r\n\r\n",
        ].map { Array($0.utf8) }
        let pieces = ["GET", "HEAD", " ", "/", "?", "#", "&", "t=", ":", "[", "]", "%", "\r\n", "Host:", "HTTP/1.",
                      "fe80::1", "172.20.10.1", "\u{0}", "é"].map { Array($0.utf8) } + [[0xFF], [0xC3]]
        var random = Seeded(state: 157)
        for i in 0..<100_000 {
            var bytes = seeds[i % seeds.count]
            for _ in 0..<Int.random(in: 1...8, using: &random) {
                let at = Int.random(in: 0...bytes.count, using: &random)
                switch Int.random(in: 0..<3, using: &random) {
                case 0 where at < bytes.count: bytes[at] = UInt8.random(in: 0...255, using: &random)
                case 1 where at < bytes.count: bytes.remove(at: at)
                default: bytes.insert(contentsOf: pieces.randomElement(using: &random)!, at: at)
                }
            }
            let text = String(data: Data(bytes), encoding: .utf8)
            let request = ConfigPage.Request(Data(bytes), hosts: ["172.20.10.1", "fe80::1"])
            if text?.contains("\r\n") != true {
                XCTAssertEqual(request, .malformed, "iteration \(i)")
            }
            if request == .config || request == .configHead {
                XCTAssertTrue(text?.contains("t=\(ConfigPage.token)") == true, "iteration \(i): a config without the token")
            }
        }
    }
}
