import Foundation

struct APIModel: Decodable, Equatable, Sendable {
    let id: String
    let name: String?
    let url: String
    let method: String
    let headers: [String: JSONValue]?
    let body: JSONValue?
    let bodyType: String?
    init(
        id: String,
        name: String?,
        url: String,
        method: String,
        headers: [String: JSONValue]?,
        body: JSONValue?,
        bodyType: String?
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.bodyType = bodyType
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case url
        case method
        case headers
        case body
        case bodyType
    }
}
