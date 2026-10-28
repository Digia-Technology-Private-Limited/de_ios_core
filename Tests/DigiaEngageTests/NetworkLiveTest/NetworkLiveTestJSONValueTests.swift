import Foundation
import Testing
@testable import DigiaEngage

/// `JSONValue` carries survey canvases and survey answers between the wire, the renderer and
/// the `survey_response` event. Only its decisions are pinned here: which case a JSON scalar
/// becomes (a `true` must stay a bool and a `1` a number, or a rating answer reads as a
/// yes/no and vice versa), and that a nested document survives a round trip unchanged.
/// Plain case-to-case mapping is not tested.
@Suite("Models: JSONValue", .tags(.contract, .network))
struct NetworkLiveTestJSONValueTests {

    private func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    @Test("a bool stays a bool, an integer an int, a fraction a double")
    func scalarCases() throws {
        // Fails if: JSONValue.init(from:) probes Int before Bool (`true` → .int(1)), or Bool
        // accepts a number, or Double before Int (every rating becomes 3.0).
        #expect(try decode("[true, false, 1, 0, 3, -7, 1.5, \"1\", null]") == .array([
            .bool(true), .bool(false), .int(1), .int(0), .int(3), .int(-7), .double(1.5), .string("1"), .null,
        ]))
    }

    @Test("a nested document survives decode → encode → decode unchanged")
    func nestedRoundTrip() throws {
        let original = try decode(#"""
            {"step":"q1","answer":{"rating":4,"liked":true,"score":0.25,"tags":["a",null,{"deep":[1,[false]]}]},"empty":{},"none":null}
            """#)

        let reencoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(original))

        // Fails if: encode(to:) writes a case as another type, or the keyed/unkeyed probes in
        // init(from:) lose an empty container or a null member.
        #expect(reencoded == original)
        guard case .object(let root) = original, case .object(let answer)? = root["answer"] else {
            Issue.record("not an object: \(original)")
            return
        }
        #expect(root["empty"] == .object([:]))
        #expect(root["none"] == .null)
        #expect(answer["rating"] == .int(4))
        #expect(answer["liked"] == .bool(true))
    }

    @Test("anyValue gives Foundation types JSONSerialization can write back")
    func anyValueIsSerializable() throws {
        let value = try decode(#"{"rating":4,"liked":true,"tags":["a",{"deep":1.5}]}"#)

        let any = try #require(value.anyValue as? [String: Any])
        // The analytics path serializes this map; a Swift-only type in it would throw there.
        let data = try JSONSerialization.data(withJSONObject: any, options: [.sortedKeys])
        #expect(String(decoding: data, as: UTF8.self) == #"{"liked":true,"rating":4,"tags":["a",{"deep":1.5}]}"#)
    }
}
