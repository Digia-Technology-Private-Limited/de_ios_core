import Foundation
import Testing
@testable import DigiaEngage

/// Flutter: `test/app_event_validation_test.dart`.
@Suite("AppEventValidation")
struct DMCAppEventValidationTests {
    @Test("keeps the types the backend stores and drops the rest by key")
    func keepsStoredTypes() {
        let long = String(repeating: "a", count: appEventPropertyStringMaxLength + 88)
        let cut = String(repeating: "a", count: appEventPropertyStringMaxLength)
        let result = cleanAppEventProperties([
            "note": long,
            "count": 3,
            "price": 4.5,
            "paid": true,
            "tags": ["ok", long, NSNull(), ["x": 1], 2] as [Any],
            "missing": NSNull(),
            "cart": ["items": 2],
            "when": Date(timeIntervalSince1970: 0),
            "ratio": Double.nan,
        ])

        #expect(result.properties["note"] as? String == cut)
        #expect(result.properties["count"] as? Int == 3)
        #expect(result.properties["price"] as? Double == 4.5)
        #expect(result.properties["paid"] as? Bool == true)
        let tags = result.properties["tags"] as? [Any]
        #expect(tags?.count == 3)
        #expect(tags?[0] as? String == "ok")
        #expect(tags?[1] as? String == cut)
        #expect(tags?[2] as? Int == 2)
        #expect(Set(result.properties.keys) == ["note", "count", "price", "paid", "tags"])
        #expect(Set(result.dropped) == ["tags", "missing", "cart", "when", "ratio"])
    }

    @Test("a long list is cut to the item limit without counting as dropped")
    func longListIsCut() {
        let result = cleanAppEventProperties([
            "skus": [String](repeating: "sku", count: appEventPropertyListMaxItems + 5)
        ])

        #expect((result.properties["skus"] as? [Any])?.count == appEventPropertyListMaxItems)
        #expect(result.dropped.isEmpty)
    }

    @Test("a cut never splits a surrogate pair")
    func cutKeepsSurrogatePair() {
        let value = String(repeating: "a", count: appEventPropertyStringMaxLength - 1) + "😀tail"

        #expect(
            cleanAppEventProperties(["note": value]).properties["note"] as? String
                == String(repeating: "a", count: appEventPropertyStringMaxLength - 1)
        )
    }
}
