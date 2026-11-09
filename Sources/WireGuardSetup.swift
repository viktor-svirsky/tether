import CryptoKit
import Foundation
import Security

/// Where Tether listens on a hotspot that gives devices IPv4, see `Interfaces.hotspotAddress`.
enum Hotspot {
    static let host = "172.20.10.1"

    /// host as it goes before a port: an IPv6 address in brackets.
    static func withPort(_ host: String, _ port: UInt16) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

/// The WireGuard way in: each device gets its own key and an address inside the tunnel, and
/// imports a config that points at the hotspot. WireGuardServer.swift runs the server side.
/// Foundation only, so `swift test` covers it.
struct WireGuardSetup: Codable, Equatable {
    static let port: UInt16 = 51820
    /// The same as MTU in WireGuard/server.go.
    static let mtu = 1420
    private static let subnet = "10.7.0."

    /// A device as the server knows it. No private key: the device has its own copy, and the
    /// server only needs the public one. Older versions saved one here, and decoding drops it.
    /// It's saved as an empty `privateKey` all the same, since older versions can't decode a
    /// device without one, and an older release can be installed over this one.
    struct Peer: Codable, Hashable, Identifiable {
        var id = UUID()
        var name: String
        var publicKey: Data
        var address: String
        /// Where its config points: the hotspot address Tether listened on when the device got its
        /// config, or when it last connected. Nil for a device saved before Tether kept it, until it
        /// connects. See `HotspotSession.needsNewConfig`.
        var host: String?
        /// Why it can't connect until it's resumed, nil when it can. It stays on the server, so its
        /// tunnel stays up, but the server lets none of its traffic through. A setup saved before
        /// there was pausing has none. A release before it, installed over this one, drops it, and the
        /// device connects again there.
        var paused: Pause?
        /// Its data limit per month in bytes, both ways, see `DataLimit`. Nil for none. A release
        /// before it, installed over this one, drops it.
        var limit: UInt64?

        private enum SavedKeys: String, CodingKey { case id, name, privateKey, publicKey, address, host, paused, limit }

        func encode(to encoder: Encoder) throws {
            try encode(to: encoder, privateKey: Data())
        }

        /// With the ready device's key, or an empty one for everyone else.
        fileprivate func encode(to encoder: Encoder, privateKey: Data) throws {
            var container = encoder.container(keyedBy: SavedKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(privateKey, forKey: .privateKey)
            try container.encode(publicKey, forKey: .publicKey)
            try container.encode(address, forKey: .address)
            try container.encodeIfPresent(host, forKey: .host)
            try container.encodeIfPresent(paused, forKey: .paused)
            try container.encodeIfPresent(limit, forKey: .limit)
        }
    }

    /// Why a device is paused, saved as `{"why": "you"}` or `{"why": "limit"}`. Each reason has its
    /// own words, see `DeviceStatus`. A reason this version doesn't know, from a newer one, reads as
    /// paused by you, so the device stays paused and can be resumed here. Saved again, it's saved as that.
    enum Pause: Codable, Hashable {
        /// Paused on its screen, until it's resumed there.
        case byYou
        /// It used its data limit for the month, see `Peer.limit`. It connects again when the count
        /// starts over on the 1st, or when it's resumed. An older release reads it as paused by you.
        case atLimit

        private enum CodingKeys: String, CodingKey { case why }

        /// Whatever was saved, so a newer version's shape never makes the setup unreadable.
        init(from decoder: Decoder) throws {
            let why = try? decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .why)
            self = why == "limit" ? .atLimit : .byYou
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .byYou: try container.encode("you", forKey: .why)
            case .atLimit: try container.encode("limit", forKey: .why)
            }
        }
    }

    /// The device behind the QR code, the only one whose private key Tether keeps: the code is its
    /// config. Saved flat, like a peer with its `privateKey`, the way older versions saved it.
    @dynamicMemberLookup
    struct Ready: Codable, Hashable {
        var peer: Peer
        var privateKey: Data

        subscript<T>(dynamicMember path: WritableKeyPath<Peer, T>) -> T {
            get { peer[keyPath: path] }
            set { peer[keyPath: path] = newValue }
        }

        init(peer: Peer, privateKey: Data) {
            self.peer = peer
            self.privateKey = privateKey
        }

        private enum CodingKeys: String, CodingKey { case privateKey }

        init(from decoder: Decoder) throws {
            peer = try Peer(from: decoder)
            privateKey = try decoder.container(keyedBy: CodingKeys.self).decode(Data.self, forKey: .privateKey)
        }

        func encode(to encoder: Encoder) throws {
            try peer.encode(to: encoder, privateKey: privateKey)
        }
    }

    var serverPrivateKey: Data
    /// The devices someone has used, in the order they first connected.
    var peers: [Peer]
    /// The device behind the QR code in the Add a device sheet: a key nobody has used yet. The server lets
    /// it in while Add a device is open (see `AddWindow`), and the first time it
    /// connects it joins `peers`, without its private key, and a new one takes its place. Nil only in a
    /// setup saved before there was one, or with all 253 addresses taken.
    var ready: Ready?

    /// Everyone the server can let in: the devices, and whoever scans the QR code next.
    var serverPeers: [Peer] { peers + (ready.map { [$0.peer] } ?? []) }

    var serverPublicKey: Data { Self.publicKey(of: serverPrivateKey) }

    static func new() -> WireGuardSetup {
        WireGuardSetup(serverPrivateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation, peers: [])
    }

    static func publicKey(of privateKey: Data) -> Data {
        (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey))?.publicKey.rawRepresentation ?? Data()
    }

    /// Lists a device with a new key and the lowest free address, as if it had used the QR code, so
    /// its private key isn't kept. Nil when all 253 addresses are taken. For demos and tests.
    mutating func addPeer(name: String, host: String? = nil) -> Peer? {
        guard var peer = newReady()?.peer else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        peer.name = trimmed.isEmpty ? freeName("Device") : trimmed
        peer.host = host
        peers.append(peer)
        return peer
    }

    /// Makes the ready device when there is none. It keeps its key until someone uses it.
    mutating func prepareReady() {
        if ready == nil { ready = newReady() }
    }

    /// The ready device connected for the first time from `address`, or its config was downloaded
    /// from the page, pointing at `host`: it's listed from now on, without its private key, and a new
    /// one is ready for the next device. False when `address` isn't the ready device's.
    mutating func claimReady(address: String, host: String) -> Bool {
        guard var peer = ready?.peer, peer.address == address else { return false }
        peer.name = freeName("Device")
        peer.host = host
        peers.append(peer)
        ready = nil
        prepareReady()
        return true
    }

    /// A new key at the lowest address nobody has, the ready device included. Unnamed.
    private func newReady() -> Ready? {
        let used = Set(serverPeers.map(\.address))
        guard let host = (2...254).first(where: { !used.contains(Self.subnet + String($0)) }) else { return nil }
        let key = Curve25519.KeyAgreement.PrivateKey()
        return Ready(peer: Peer(name: "", publicKey: key.publicKey.rawRepresentation, address: Self.subnet + String(host)),
                     privateKey: key.rawRepresentation)
    }

    mutating func removePeer(_ id: Peer.ID) {
        peers.removeAll { $0.id == id }
    }

    /// Pauses the device, or resumes it with nil, see `Peer.paused`.
    mutating func pausePeer(_ id: Peer.ID, _ pause: Pause?) {
        guard let i = peers.firstIndex(where: { $0.id == id }) else { return }
        peers[i].paused = pause
    }

    /// Its data limit per month in bytes, or nil for none, see `Peer.limit`.
    mutating func limitPeer(_ id: Peer.ID, _ limit: UInt64?) {
        guard let i = peers.firstIndex(where: { $0.id == id }) else { return }
        peers[i].limit = limit
    }

    /// The devices at these tunnel addresses reach Tether at `host`, see `Peer.host`.
    mutating func pointPeers(_ addresses: Set<String>, at host: String) {
        for i in peers.indices where addresses.contains(peers[i].address) { peers[i].host = host }
    }

    /// "Device", then "Device 2", "Device 3", skipping names already taken.
    private func freeName(_ base: String) -> String {
        guard peers.contains(where: { $0.name == base }) else { return base }
        var number = 2
        while peers.contains(where: { $0.name == "\(base) \(number)" }) { number += 1 }
        return "\(base) \(number)"
    }

    /// A blank name leaves the old one. A long one is cut to 40 characters, which still fits a list row.
    mutating func renamePeer(_ id: Peer.ID, to name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !trimmed.isEmpty, let i = peers.firstIndex(where: { $0.id == id }) else { return }
        peers[i].name = trimmed
    }

    /// What the next device imports, as a QR code or a .conf file. Only the ready device has one,
    /// since only its private key is kept. All traffic goes into the tunnel, IPv6 too, so nothing
    /// slips past Tether onto the hotspot directly. `dns` is the DNS line, see `DNSChoice`.
    func clientConfig(for ready: Ready, host: String = Hotspot.host, dns: String) -> String {
        """
        [Interface]
        PrivateKey = \(ready.privateKey.base64EncodedString())
        Address = \(ready.address)/32
        DNS = \(dns)
        MTU = \(Self.mtu)

        [Peer]
        PublicKey = \(serverPublicKey.base64EncodedString())
        Endpoint = \(Hotspot.withPort(host, Self.port))
        AllowedIPs = 0.0.0.0/0, ::/0
        PersistentKeepalive = 25

        """
    }

    /// WireGuard names the tunnel after the file, so keep it to letters, digits and dashes.
    static func fileName(for name: String) -> String {
        let parts = name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return (["Tether"] + parts).joined(separator: "-") + ".conf"
    }
}

/// Where the setup is kept. It holds private keys, so the app keeps it in the Keychain.
protocol SecretStore: AnyObject {
    /// Nil when nothing is saved. Throws when something may be saved but can't be read now.
    func load() throws -> Data?
    func save(_ data: Data) throws
}

/// For demo launches and tests, which must not touch the Keychain.
final class InMemorySecrets: SecretStore {
    var data: Data?
    func load() -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
}

final class KeychainSecrets: SecretStore {
    private let query: [String: Any]

    /// `service` only changes in tests, which keep their own item apart from the app's.
    init(service: String = "tether.wireguard") {
        query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "setup",
        ]
    }

    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { "Keychain error \(status)" }
    }

    func load() throws -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        switch SecItemCopyMatching(q as CFDictionary, &out) {
        case errSecSuccess: return out as? Data
        case errSecItemNotFound: return nil
        case let status: throw Failure(status: status) // locked since a restart, for example
        }
    }

    func save(_ data: Data) throws {
        // After first unlock, so the server can start in the background after a restart.
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attrs) { $1 } as CFDictionary, nil)
        }
        if status != errSecSuccess { throw Failure(status: status) }
    }
}

/// The saved setup. Nothing saved starts afresh with a new server key. Anything else that goes
/// wrong leaves the saved setup alone: nothing is saved and devices can't be added, so neither a
/// passing Keychain error nor a setup this version can't decode replaces the key every device was
/// set up with. `load()` tries again, `reset()` gives up on a setup that doesn't decode.
/// `setup.ready` is only ever a saved one: a device that scanned a code that wasn't saved could
/// never connect, since the next launch would make a different one.
final class WireGuardDevices {
    struct Unreadable: Error, CustomStringConvertible {
        var description: String { "the saved WireGuard setup can't be read" }
    }

    /// New keys, from a first launch or `reset()`, that couldn't be saved. They aren't used.
    struct Unsaved: Error, CustomStringConvertible {
        let reason: Error
        var description: String { "the new WireGuard keys can't be saved: \(reason)" }
    }

    private(set) var setup = WireGuardSetup.new()
    /// Why the saved setup couldn't be read, or new keys saved, until it works.
    private(set) var loadError: Error?
    /// Why the setup that loaded has no ready device: making one couldn't be saved. `prepareReady()` tries again.
    private(set) var readyError: Error?
    private let secrets: SecretStore

    init(secrets: SecretStore) {
        self.secrets = secrets
        load()
    }

    /// Reads the saved setup, again after a failure. Does nothing once it has worked.
    func load() {
        do {
            guard let data = try secrets.load() else {
                try startAfresh()
                return
            }
            guard let saved = try? JSONDecoder().decode(WireGuardSetup.self, from: data) else { throw Unreadable() }
            setup = saved
            loadError = nil
            dropOldKeys(saved: data)
            prepareReady() // a setup saved before there were ready devices has none
        } catch {
            loadError = error
        }
    }

    /// Older versions saved every device's private key. Decoding left them out, and this saves
    /// that, so they leave the Keychain now rather than with the next change. A save that fails
    /// loses nothing: the old setup stays saved, the devices still connect, and the next save
    /// drops the keys. A dropped key is saved empty, so it isn't saved again on every launch.
    private func dropOldKeys(saved data: Data) {
        struct Old: Decodable {
            struct Device: Decodable { var privateKey: Data? }
            var peers: [Device]
        }
        guard let old = try? JSONDecoder().decode(Old.self, from: data),
              old.peers.contains(where: { !($0.privateKey ?? Data()).isEmpty }) else { return }
        try? save()
    }

    var loaded: Bool { loadError == nil }
    /// The saved setup is there but this version can't decode it, so only `reset()` gets past it.
    var needsReset: Bool { loadError is Unreadable }

    /// A new server key and no devices, replacing what's saved. Every device has to be added again.
    func reset() {
        do { try startAfresh() } catch { loadError = error }
    }

    /// A new server key and a ready device, used only once they're saved.
    private func startAfresh() throws {
        var fresh = WireGuardSetup.new()
        fresh.prepareReady()
        do { try secrets.save(JSONEncoder().encode(fresh)) } catch { throw Unsaved(reason: error) }
        setup = fresh
        loadError = nil
        readyError = nil
    }

    /// Makes the ready device when there is none, and keeps it only once it's saved. False when
    /// there's one already, all addresses are taken, or it couldn't be saved (see `readyError`).
    @discardableResult
    func prepareReady() -> Bool {
        guard loaded, setup.ready == nil else { return false }
        var next = setup
        next.prepareReady()
        guard next.ready != nil else { return false }
        do {
            try secrets.save(JSONEncoder().encode(next))
        } catch {
            readyError = error
            return false
        }
        setup = next
        readyError = nil
        return true
    }

    /// A new ready device in place of the one there is, so the old code never works again. The old one
    /// goes even when the new one can't be saved: then there's none until `prepareReady()` saves one
    /// (see `readyError`). The Keychain still has the old one then, so it comes back at the next launch,
    /// where `HotspotSession` replaces it before letting it in. False when nothing new was saved.
    @discardableResult
    func replaceReady() -> Bool {
        guard loaded else { return false }
        setup.ready = nil
        return prepareReady()
    }

    /// See `WireGuardSetup.claimReady`. False too when it couldn't be saved, and then nothing changes,
    /// so the next sample tries again.
    func claimReady(address: String, host: String) -> Bool {
        guard loaded else { return false }
        let before = setup
        guard setup.claimReady(address: address, host: host) else { return false }
        do {
            try save()
            return true
        } catch {
            setup = before
            return false
        }
    }

    /// See `WireGuardSetup.pointPeers`. Saves only when a device's host changes. False when none did,
    /// or it couldn't be saved, and then nothing changes.
    func point(_ addresses: Set<String>, at host: String) -> Bool {
        guard setup.peers.contains(where: { addresses.contains($0.address) && $0.host != host }) else { return false }
        return change { $0.pointPeers(addresses, at: host) }
    }

    /// False when the change couldn't be saved, and then nothing changes.
    @discardableResult
    func rename(_ id: WireGuardSetup.Peer.ID, to name: String) -> Bool {
        change { $0.renamePeer(id, to: name) }
    }

    private func change(_ apply: (inout WireGuardSetup) -> Void) -> Bool {
        guard loaded else { return false }
        let before = setup
        apply(&setup)
        do {
            try save()
            return true
        } catch {
            setup = before
            return false
        }
    }

    /// See `WireGuardSetup.pausePeer`. False when it couldn't be saved, and then nothing changes, since
    /// it wouldn't hold after a relaunch.
    @discardableResult
    func pause(_ id: WireGuardSetup.Peer.ID, _ pause: WireGuardSetup.Pause?) -> Bool {
        change { $0.pausePeer(id, pause) }
    }

    /// See `WireGuardSetup.limitPeer`. False when it couldn't be saved, and then nothing changes.
    @discardableResult
    func limit(_ id: WireGuardSetup.Peer.ID, _ limit: UInt64?) -> Bool {
        change { $0.limitPeer(id, limit) }
    }

    /// False when the change couldn't be saved. Then the device stays, here and on the server, since
    /// it would come back with the next launch anyway.
    @discardableResult
    func remove(_ id: WireGuardSetup.Peer.ID) -> Bool {
        change { $0.removePeer(id) }
    }

    private func save() throws {
        try secrets.save(JSONEncoder().encode(setup))
    }
}
