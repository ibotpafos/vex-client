import CryptoKit
import Foundation

struct NativePushPSKEventOwner: Codable, Equatable {
    let accountID: String
    let installationID: String

    init?(accountID: String?, installationID: String?) {
        guard let accountID = Self.clean(accountID),
              let installationID = Self.clean(installationID) else { return nil }
        self.accountID = accountID
        self.installationID = installationID
    }

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= 256,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
        return value
    }
}

struct NativePushPSKEvent: Codable, Equatable {
    enum Kind: String, Codable { case profile_updated, cutover_ready }

    let kind: Kind
    let eventID: String
    let rotationID: String
    let deviceID: String
    let profileVersion: Int
    let deadlineAt: Date?

    static func parse(_ userInfo: [String: Any]) -> NativePushPSKEvent? {
        guard let vex = userInfo["vex"] as? [String: Any],
              let type = vex["type"] as? String,
              let kind = Kind(rawValue: type),
              let eventID = id(vex["event_id"]),
              let rotationID = id(vex["rotation_id"]),
              let deviceID = id(vex["device_id"]),
              let version = strictPositiveInt(vex["profile_version"]) else { return nil }

        let deadline: Date?
        if let raw = vex["deadline_at"] as? String {
            guard raw == raw.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            if raw.isEmpty {
                deadline = nil
            } else {
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let standard = ISO8601DateFormatter()
                standard.formatOptions = [.withInternetDateTime]
                guard let parsed = fractional.date(from: raw) ?? standard.date(from: raw) else { return nil }
                deadline = parsed
            }
        } else if vex["deadline_at"] == nil {
            deadline = nil
        } else {
            return nil
        }

        return NativePushPSKEvent(kind: kind, eventID: eventID, rotationID: rotationID, deviceID: deviceID, profileVersion: version, deadlineAt: deadline)
    }

    private static func id(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 256,
              !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
        return trimmed
    }

    private static func strictPositiveInt(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        let signed = number.int64Value
        guard signed > 0,
              signed <= Int64(Int.max),
              Double(signed) == number.doubleValue else { return nil }
        return Int(signed)
    }
}

struct NativePushPSKEventQueueRecord: Codable {
    let namespace: String
    var events: [NativePushPSKEvent]
}

/// Bounded metadata-only inbox. It never contains PSKs, profiles, session tokens, acks, or VPN state.
struct NativePushPSKEventQueue {
    private let fileManager: FileManager
    private let root: URL
    private static let limit = 32
    private static let maxBytes = 64 * 1024
    init(fileManager: FileManager = .default, appDataURL: URL? = nil) {
        self.fileManager = fileManager
        self.root = appDataURL ?? (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")).appendingPathComponent("VEX Native", isDirectory: true)
    }
    @discardableResult func enqueue(_ event: NativePushPSKEvent, owner: NativePushPSKEventOwner) throws -> Bool {
        guard Self.valid(event), Self.valid(owner) else { throw CocoaError(.fileWriteInvalidFileName) }
        let store = NativePushSecureFileStore(rootURL: root, maxBytes: Self.maxBytes); try store.ensureDirectory(); let name = fileName(owner); let ns = fingerprint(owner)
        var value = try record(store, name, ns) ?? NativePushPSKEventQueueRecord(namespace: ns, events: [])
        if value.events.contains(where: { $0.eventID == event.eventID }) { return false }
        value.events.append(event); if value.events.count > Self.limit { value.events.removeFirst(value.events.count - Self.limit) }
        let data = try JSONEncoder().encode(value); guard data.count <= Self.maxBytes else { throw CocoaError(.fileWriteOutOfSpace) }; try store.write(data, name: name); return true
    }
    func events(owner: NativePushPSKEventOwner) throws -> [NativePushPSKEvent] {
        guard Self.valid(owner) else { throw CocoaError(.fileReadInvalidFileName) }; let s = NativePushSecureFileStore(rootURL: root, maxBytes: Self.maxBytes); try s.ensureDirectory(); return try record(s, fileName(owner), fingerprint(owner))?.events ?? []
    }
    func purge(owner: NativePushPSKEventOwner) throws { guard Self.valid(owner) else { throw CocoaError(.fileWriteInvalidFileName) }; try NativePushSecureFileStore(rootURL: root, maxBytes: Self.maxBytes).remove(fileName(owner)) }
    @discardableResult func remove(eventID: String, owner: NativePushPSKEventOwner) throws -> Bool {
        guard Self.valid(owner), Self.validID(eventID) else { throw CocoaError(.fileWriteInvalidFileName) }; let s = NativePushSecureFileStore(rootURL: root, maxBytes: Self.maxBytes); try s.ensureDirectory(); let n = fileName(owner); guard var v = try record(s,n,fingerprint(owner)) else { return false }; let count=v.events.count; v.events.removeAll { $0.eventID == eventID }; guard count != v.events.count else { return false }; try s.write(try JSONEncoder().encode(v), name:n); return true
    }
    private func record(_ store: NativePushSecureFileStore, _ name: String, _ namespace: String) throws -> NativePushPSKEventQueueRecord? {
        guard let data = try store.read(name) else { return nil }; let value: NativePushPSKEventQueueRecord; do { value = try JSONDecoder().decode(NativePushPSKEventQueueRecord.self, from:data) } catch { throw CocoaError(.fileReadCorruptFile) }; guard value.namespace == namespace, value.events.count <= Self.limit, value.events.allSatisfy(Self.valid), Set(value.events.map(\.eventID)).count == value.events.count else { throw CocoaError(.fileReadCorruptFile) }; return value
    }
    private func fileName(_ owner: NativePushPSKEventOwner) -> String { fingerprint(owner) + ".json" }
    private func fingerprint(_ owner: NativePushPSKEventOwner) -> String { digest(lengthPrefixed([owner.accountID,owner.installationID])) }
    private func lengthPrefixed(_ values:[String]) -> Data { var r=Data(); for v in values { let b=Data(v.utf8); var n=UInt64(b.count).bigEndian; withUnsafeBytes(of:&n) { r.append(contentsOf:$0) }; r.append(b) }; return r }
    private func digest(_ data:Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    private static func valid(_ owner: NativePushPSKEventOwner) -> Bool { NativePushPSKEventOwner(accountID:owner.accountID,installationID:owner.installationID) == owner }
    private static func valid(_ event: NativePushPSKEvent) -> Bool { event.profileVersion > 0 && validID(event.eventID) && validID(event.rotationID) && validID(event.deviceID) && (event.deadlineAt?.timeIntervalSinceReferenceDate.isFinite ?? true) }
    private static func validID(_ value:String) -> Bool { !value.isEmpty && value == value.trimmingCharacters(in:.whitespacesAndNewlines) && value.utf8.count <= 256 && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) }
}
