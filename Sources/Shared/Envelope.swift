import Foundation

// MARK: - Wire format
//
// FROZEN CONTRACT (orchestrator-owned).
//
// Transport: Unix domain stream socket, newline-delimited JSON (NDJSON). One JSON object per
// line, UTF-8, no embedded newlines, max `Defaults.maxLineBytes` per line.
// A connection may carry many requests sequentially; each request gets exactly one response
// with the same `id`, except `subscribe` (fand), which answers with a stream of responses
// (all with the subscribe request's `id`) until the client closes.
//
// Request:   {"v":1,"id":"<client-chosen>","op":"<op>","body":{...}}      body omitted if empty
// Success:   {"v":1,"id":"<same>","op":"<op>","ok":true,"body":{...}}     body omitted if empty
// Failure:   {"v":1,"id":"<same>","op":"<op>","ok":false,"error":{"code":"notImplemented","message":"..."}}
//
// Dates are encoded as seconds since 1970 (Double); durations as seconds (Double) in fields
// suffixed `Seconds`. Sum types inside bodies carry a `"kind"` discriminator.

/// Protocol versions. A server rejects other versions with `unsupportedVersion`.
public enum ProtocolVersion {
    public static let fand = 1
    public static let gate = 1
}

/// Envelope JSON keys.
public enum EnvelopeKey: String, CodingKey {
    case v, id, op, ok, body, error
}

/// A request or reply message: an enum whose case is selected by `op`.
public protocol OpMessage: Sendable, Equatable {
    /// Protocol version of the family this message belongs to.
    static var version: Int { get }
    var op: String { get }
    /// Encode this message's body under `.body` (omit when the op has no body).
    func encodeBody(into container: inout KeyedEncodingContainer<EnvelopeKey>) throws
    /// Decode the body for `op` from `.body`.
    init(op: String, from container: KeyedDecodingContainer<EnvelopeKey>) throws
}

/// Error codes carried in failure responses.
public enum WireErrorCode: String, Codable, Sendable {
    /// Placeholder handler; op exists but is not implemented yet.
    case notImplemented
    /// Malformed JSON, missing fields, line too long.
    case badRequest
    case unknownOp
    case unsupportedVersion
    /// Peer UID check failed (fand).
    case unauthorized
    /// Request valid but not applicable in current state (e.g. unknown job id).
    case invalidState
    case `internal`
}

public struct WireError: Error, Codable, Sendable, Equatable {
    public var code: WireErrorCode
    public var message: String

    public init(_ code: WireErrorCode, _ message: String = "") {
        self.code = code
        self.message = message
    }

    public static func notImplemented(_ op: String) -> WireError {
        WireError(.notImplemented, "op '\(op)' not implemented")
    }
}

/// Request envelope.
public struct Request<M: OpMessage>: Codable, Sendable, Equatable {
    public var v: Int
    public var id: String
    public var message: M

    public init(id: String = UUID().uuidString, _ message: M) {
        self.v = M.version
        self.id = id
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: EnvelopeKey.self)
        v = try c.decode(Int.self, forKey: .v)
        id = try c.decode(String.self, forKey: .id)
        guard v == M.version else {
            throw WireError(.unsupportedVersion, "expected v\(M.version), got v\(v)")
        }
        let op = try c.decode(String.self, forKey: .op)
        message = try M(op: op, from: c)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EnvelopeKey.self)
        try c.encode(v, forKey: .v)
        try c.encode(id, forKey: .id)
        try c.encode(message.op, forKey: .op)
        try message.encodeBody(into: &c)
    }
}

/// Response envelope: either a reply message or an error.
public struct Response<M: OpMessage>: Codable, Sendable, Equatable {
    public var v: Int
    public var id: String
    /// Echo of the request op (also set on failures).
    public var op: String
    public var result: Result<M, WireError>

    public init(id: String, _ reply: M) {
        self.v = M.version
        self.id = id
        self.op = reply.op
        self.result = .success(reply)
    }

    public init(id: String, op: String, error: WireError) {
        self.v = M.version
        self.id = id
        self.op = op
        self.result = .failure(error)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: EnvelopeKey.self)
        v = try c.decode(Int.self, forKey: .v)
        id = try c.decode(String.self, forKey: .id)
        op = try c.decode(String.self, forKey: .op)
        if try c.decode(Bool.self, forKey: .ok) {
            result = .success(try M(op: op, from: c))
        } else {
            result = .failure(try c.decode(WireError.self, forKey: .error))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EnvelopeKey.self)
        try c.encode(v, forKey: .v)
        try c.encode(id, forKey: .id)
        try c.encode(op, forKey: .op)
        switch result {
        case .success(let m):
            try c.encode(true, forKey: .ok)
            try m.encodeBody(into: &c)
        case .failure(let e):
            try c.encode(false, forKey: .ok)
            try c.encode(e, forKey: .error)
        }
    }
}

/// Shared JSON coders: dates as seconds since 1970, sorted keys (stable, diffable output).
public enum WireCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    /// Encode one value as a single NDJSON line (without trailing newline).
    public static func line<T: Encodable>(_ value: T) throws -> Data {
        try encoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, line: Data) throws -> T {
        try decoder().decode(type, from: line)
    }
}

/// Empty body marker, used for acknowledgements.
public struct Empty: Codable, Sendable, Equatable {
    public init() {}
}

// MARK: - Helpers for OpMessage implementations

extension KeyedDecodingContainer where K == EnvelopeKey {
    /// Decode the body; throws `badRequest` if missing.
    public func body<T: Decodable>(_ type: T.Type) throws -> T {
        try decode(T.self, forKey: .body)
    }
}

/// Discriminated-union helper: encodes `{"kind": "<kind>", ...payload fields}`.
public enum KindKey: String, CodingKey { case kind }

extension Encoder {
    public func encodeKind<P: Encodable>(_ kind: String, _ payload: P?) throws {
        if let payload { try payload.encode(to: self) }
        var c = container(keyedBy: KindKey.self)
        try c.encode(kind, forKey: .kind)
    }
}

extension Decoder {
    public func decodeKind() throws -> String {
        try container(keyedBy: KindKey.self).decode(String.self, forKey: .kind)
    }
}
