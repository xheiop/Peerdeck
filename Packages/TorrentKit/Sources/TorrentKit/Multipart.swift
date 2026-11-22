import Foundation

public struct Multipart: Sendable {
    public let boundary: String
    private var body = Data()

    public init(boundary: String = "tc-" + UUID().uuidString) {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func field(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    public mutating func file(_ name: String, filename: String, contentType: String, data: Data) {
        let safe = filename.replacingOccurrences(of: "\"", with: "_")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(safe)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    public func finish() -> Data {
        body + Data("--\(boundary)--\r\n".utf8)
    }
}
