import Foundation
import Testing
@testable import DigiaEngage

@Suite("Nudge variable handling", .tags(.nudge, .unit))
struct NudgeVariableHandlingTests {

    // MARK: - 1. stringifyVariable Pure Value Transformer

    @Test("stringifyVariable handles strings, numbers, booleans, and rejects collections/nil")
    func testStringifyVariable() {
        // Strings
        #expect(NudgeConfig.stringifyVariable("hello") == "hello")
        #expect(NudgeConfig.stringifyVariable("") == "")

        // Numbers
        #expect(NudgeConfig.stringifyVariable(42) == "42")
        #expect(NudgeConfig.stringifyVariable(NSNumber(value: 100)) == "100")
        #expect(NudgeConfig.stringifyVariable(3.14) == "3.14")

        // Booleans
        #expect(NudgeConfig.stringifyVariable(true) == "true")
        #expect(NudgeConfig.stringifyVariable(false) == "false")
        #expect(NudgeConfig.stringifyVariable(NSNumber(value: true)) == "true")
        #expect(NudgeConfig.stringifyVariable(NSNumber(value: false)) == "false")

        // Nil and unsupported types
        #expect(NudgeConfig.stringifyVariable(nil) == nil)
        #expect(NudgeConfig.stringifyVariable(NSNull()) == nil)
        #expect(NudgeConfig.stringifyVariable(["a", "b"]) == nil)
        #expect(NudgeConfig.stringifyVariable(["key": "val"]) == nil)
    }

    // MARK: - 2. parseVariableSchemas List and Map Schemas

    @Test("parseVariableSchemas parses list schema with full, fallback-to-sample, and default type")
    func testParseVariableSchemasList() {
        let template: [String: Any] = [
            "variables": [
                // 1. Fully specified
                [
                    "name": "firstName",
                    "type": "string",
                    "fallbackValue": "Guest",
                    "sampleValue": "Alice"
                ],
                // 2. Absent type defaults to string, absent fallbackValue uses sampleValue
                [
                    "name": "points",
                    "sampleValue": 500
                ],
                // 3. Fallback value with number
                [
                    "name": "score",
                    "type": "number",
                    "fallbackValue": 42
                ],
                // 4. Non-number types (e.g. boolean) normalize to string
                [
                    "name": "isMember",
                    "type": "boolean",
                    "fallbackValue": false
                ],
                // 5. Empty name should be skipped
                [
                    "name": "",
                    "type": "string"
                ],
                // 6. Missing name should be skipped
                [
                    "type": "string",
                    "fallbackValue": "invalid"
                ]
            ]
        ]

        let schemas = NudgeConfig.parseVariableSchemas(template)
        #expect(schemas.count == 4)

        #expect(schemas[0].name == "firstName")
        #expect(schemas[0].type == "string")
        #expect(schemas[0].fallbackValue == "Guest")

        #expect(schemas[1].name == "points")
        #expect(schemas[1].type == "string")
        #expect(schemas[1].fallbackValue == "500")

        #expect(schemas[2].name == "score")
        #expect(schemas[2].type == "number")
        #expect(schemas[2].fallbackValue == "42")

        #expect(schemas[3].name == "isMember")
        #expect(schemas[3].type == "string")
        #expect(schemas[3].fallbackValue == "false")
    }

    @Test("parseVariableSchemas parses map schema for forward compatibility")
    func testParseVariableSchemasMap() {
        let template: [String: Any] = [
            "variables": [
                "username": "johndoe",
                "score": 99,
                "verified": true,
                "unsupported": ["nested": "object"]
            ]
        ]

        let schemas = NudgeConfig.parseVariableSchemas(template)
        let schemaMap = Dictionary(uniqueKeysWithValues: schemas.map { ($0.name, $0) })

        #expect(schemaMap.count == 3)

        #expect(schemaMap["username"]?.fallbackValue == "johndoe")
        #expect(schemaMap["username"]?.type == "string")

        #expect(schemaMap["score"]?.fallbackValue == "99")
        #expect(schemaMap["score"]?.type == "string")

        #expect(schemaMap["verified"]?.fallbackValue == "true")
        #expect(schemaMap["verified"]?.type == "string")

        #expect(schemaMap["unsupported"] == nil)
    }

    @Test("parseVariableSchemas returns empty array when variables key is absent or invalid")
    func testParseVariableSchemasEmpty() {
        #expect(NudgeConfig.parseVariableSchemas([:]).isEmpty)
        #expect(NudgeConfig.parseVariableSchemas(["variables": "not_a_collection"]).isEmpty)
    }
}
