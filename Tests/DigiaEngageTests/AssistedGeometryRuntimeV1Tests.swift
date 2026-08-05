import Foundation
@testable import DigiaEngage
import XCTest

final class AssistedGeometryRuntimeV1Tests: XCTestCase {
    private let stepId = "fd7d350d-e586-4a42-83f0-764f3393436e"

    func testMatchesEveryCanonicalIOSRuntimeVector() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/assisted-geometry-vectors.json")
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )
        let vectors = try XCTUnwrap(document["runtimeVectors"] as? [[String: Any]])
        var matched = 0
        for vector in vectors where vector["platform"] as? String == "ios" {
            matched += 1
            let variant = deepMerge(baseIOSVariant(), vector["variantPatch"] as? [String: Any])
            guard case .prepared(let prepared) = AssistedGeometryRuntimeV1.prepare(
                campaign(variant), platform: .ios
            ) else {
                return XCTFail("\(vector["name"] ?? "iOS vector") did not prepare")
            }
            let snapshot = RuntimeGeometrySnapshotV1.fromJson(
                try XCTUnwrap(vector["snapshot"] as? [String: Any])
            )
            let expected = try XCTUnwrap(vector["expected"] as? [String: Any])
            let resolution = AssistedGeometryRuntimeV1.resolve(
                prepared, stepId: stepId, snapshot: snapshot
            )
            guard case .resolved(_, let rounded, let overlay, let warnings, _) = resolution else {
                return XCTFail("\(vector["name"] ?? "iOS vector") unexpectedly failed")
            }
            let expectedRounded = try XCTUnwrap(expected["roundedTargetPx"] as? [String: Any])
            let expectedOverlay = try XCTUnwrap(expected["overlayTarget"] as? [String: Any])
            XCTAssertEqual(rounded, try rect(expectedRounded))
            XCTAssertEqual(overlay.left, try number(expectedOverlay, "left"), accuracy: 0.000001)
            XCTAssertEqual(overlay.top, try number(expectedOverlay, "top"), accuracy: 0.000001)
            XCTAssertEqual(overlay.right, try number(expectedOverlay, "right"), accuracy: 0.000001)
            XCTAssertEqual(overlay.bottom, try number(expectedOverlay, "bottom"), accuracy: 0.000001)
            XCTAssertEqual(warnings.map(\.rawValue), expected["warnings"] as? [String] ?? [])
        }
        XCTAssertGreaterThan(matched, 0)
    }

    func testCampaignParserPreparesAssistedGeometryBeforePresentation() throws {
        let parsed = try XCTUnwrap(CampaignModel.fromJson(campaign(baseIOSVariant())))
        let guide = try XCTUnwrap(parsed.guideConfig)
        XCTAssertEqual(guide.steps.first?.assistedStepId, stepId)
        XCTAssertNil(guide.steps.first?.semanticTarget)
        XCTAssertEqual(guide.assistedCampaign?.steps.count, 1)
    }

    @MainActor
    func testAssistedGuideUsesNativeRendererWhenReactNativeGuideCallbackExists() throws {
        SDKInstance.shared.resetForTesting()
        defer {
            SDKInstance.shared.onGuideRenderRequest = nil
            SDKInstance.shared.resetForTesting()
        }
        var reactNativeRenderRequested = false
        SDKInstance.shared.onGuideRenderRequest = { _ in reactNativeRenderRequested = true }
        let parsed = try XCTUnwrap(CampaignModel.fromJson(campaign(baseIOSVariant())))
        SDKInstance.shared.setCampaignsForTesting([parsed])
        SDKInstance.shared.setCurrentScreen("home")

        let accepted = SDKInstance.shared.onCampaignTriggered(
            CEPTriggerPayload(
                cepCampaignId: "assisted-trigger",
                campaignKey: parsed.campaignKey,
                cepMetadata: [:]
            )
        )

        XCTAssertTrue(accepted)
        XCTAssertFalse(reactNativeRenderRequested)
        XCTAssertEqual(SDKInstance.shared.guideOrchestrator.state?.campaign.campaignKey, parsed.campaignKey)
    }

    func testRejectsMixedAnchorAndAssistedCampaignAsOneUnit() {
        var raw = campaign(baseIOSVariant())
        var config = raw["templateConfig"] as! [String: Any]
        var steps = config["steps"] as! [[String: Any]]
        steps.append(["stepId": "25ca2e99-2a7d-409c-8d01-04f66013c494", "anchorKey": "legacy"])
        config["steps"] = steps
        raw["templateConfig"] = config

        guard case .rejected(let failure, _) = AssistedGeometryRuntimeV1.prepare(raw, platform: .ios)
        else { return XCTFail("mixed campaign unexpectedly prepared") }
        XCTAssertEqual(failure, .campaignModeMismatch)
        XCTAssertNil(CampaignModel.fromJson(raw))
    }

    func testTypedGeometryParsesAndResolvesWithoutLegacyFallback() throws {
        let targetJson: [String: Any] = [
            "type": "geometry",
            "version": 1,
            "pageKey": "home",
            "orientation": "portrait",
            "source": [
                "density": 3,
                "windowBoundsPx": ["left": 0, "top": 0, "right": 1080, "bottom": 2400],
                "appContentBoundsPx": ["left": 0, "top": 0, "right": 1080, "bottom": 2400],
                "layoutDirection": "ltr",
            ],
            "rectPx": ["x": 360, "y": 2250, "width": 270, "height": 150],
            "constraints": [
                "frame": "window",
                "horizontal": "proportional",
                "vertical": "bottomFixed",
            ],
        ]
        let target = try XCTUnwrap(TypedGeometryTargetV1.fromJson(targetJson))
        let rect = try XCTUnwrap(target.resolve(snapshot: RuntimeGeometrySnapshotV1(
            snapshotVersion: 1,
            platform: .ios,
            pageKey: "home",
            density: 3,
            windowBoundsPx: EdgeRectV1(left: 0, top: 0, right: 1179, bottom: 2556),
            appContentBoundsPx: EdgeRectV1(left: 0, top: 0, right: 1179, bottom: 2556),
            layoutDirection: "ltr",
            orientation: "portrait",
            formFactor: "phone",
            appIdentifier: "app",
            appBuild: "1",
            locale: "en-IN",
            fontScale: 1
        )))

        XCTAssertEqual(rect.minX, 131, accuracy: 0.000001)
        XCTAssertEqual(rect.maxX, 688 / 3, accuracy: 0.000001)
        XCTAssertEqual(rect.minY, 802, accuracy: 0.000001)
        XCTAssertEqual(rect.maxY, 852, accuracy: 0.000001)
        XCTAssertNil(TypedGeometryTargetV1.fromJson([
            "region": ["xFrac": 0.25, "wFrac": 0.25],
        ]))
    }

    func testDiagnosticsFIFOObserveAndClear() {
        let diagnostics = AssistedGeometryDiagnosticsV1(capacity: 100)
        var observed: [String?] = []
        let token = diagnostics.observe { observed.append($0.stepId) }
        for index in 0..<101 {
            diagnostics.append(AssistedGeometryTraceV1(
                outcome: "resolved",
                campaignKey: "campaign",
                stepId: "step-\(index)",
                variantId: "variant",
                captureId: "capture",
                warnings: [],
                failure: nil,
                roundedTargetPx: EdgeRectV1(left: 0, top: 0, right: 1, bottom: 1)
            ))
        }
        diagnostics.removeObserver(token)
        diagnostics.append(AssistedGeometryTraceV1(
            outcome: "resolved",
            campaignKey: "campaign",
            stepId: "not-observed",
            variantId: "variant",
            captureId: "capture",
            warnings: [],
            failure: nil,
            roundedTargetPx: EdgeRectV1(left: 0, top: 0, right: 1, bottom: 1)
        ))

        XCTAssertEqual(diagnostics.snapshot().count, 100)
        XCTAssertEqual(diagnostics.snapshot().first?.stepId, "step-2")
        XCTAssertEqual(observed.count, 101)
        diagnostics.clear()
        XCTAssertTrue(diagnostics.snapshot().isEmpty)
    }

    private func campaign(_ variant: [String: Any]) -> [String: Any] {
        [
            "id": "campaign-assisted-id",
            "campaignKey": "campaign-assisted",
            "campaignType": "guide",
            "templateConfig": [
                "templateType": "spotlight",
                "deliveryPlatforms": ["ios"],
                "steps": [[
                    "stepId": stepId,
                    "target": [
                        "type": "assistedGeometry",
                        "version": 1,
                        "variants": ["ios": variant],
                    ],
                    "title": "Feature highlight",
                    "body": "Take a closer look at this element.",
                ]],
            ],
        ]
    }

    private func baseIOSVariant() -> [String: Any] {
        [
            "variantId": "c29ef48d-ccad-4fab-a573-725f76fb0236",
            "captureId": "cap_testkit_ios_home_001",
            "platform": "ios",
            "pageKey": "home",
            "orientation": "portrait",
            "logicalUnit": "pt",
            "source": [
                "density": 3,
                "windowBoundsPx": ["left": 0, "top": 0, "right": 1179, "bottom": 2556],
                "appContentBoundsPx": ["left": 0, "top": 0, "right": 1179, "bottom": 2556],
                "layoutDirection": "ltr",
            ],
            "comparisonContext": [
                "appIdentifier": "com.digia.medihub.rn.clevertap",
                "appBuild": "1",
                "locale": "en-IN",
                "fontScale": 1,
                "riskFlags": [],
            ],
            "authorIntentPx": ["left": 295, "top": 2376, "right": 590, "bottom": 2536],
            "referenceContainer": NSNull(),
            "model": [
                "version": 1,
                "horizontal": [
                    "frame": "window",
                    "rule": ["kind": "proportional", "startFraction": 0.25, "endFraction": 0.5],
                ],
                "vertical": [
                    "frame": "window",
                    "rule": ["kind": "bottomFixed", "bottomOffset": 6.666667, "height": 53.333333],
                ],
            ],
        ]
    }

    private func deepMerge(_ base: [String: Any], _ patch: [String: Any]?) -> [String: Any] {
        guard let patch else { return base }
        var result = base
        for (key, value) in patch {
            if let left = result[key] as? [String: Any], let right = value as? [String: Any] {
                result[key] = deepMerge(left, right)
            } else {
                result[key] = value
            }
        }
        return result
    }

    private func number(_ json: [String: Any], _ key: String) throws -> Double {
        try XCTUnwrap(json[key] as? NSNumber).doubleValue
    }

    private func rect(_ json: [String: Any]) throws -> EdgeRectV1 {
        EdgeRectV1(
            left: try number(json, "left"),
            top: try number(json, "top"),
            right: try number(json, "right"),
            bottom: try number(json, "bottom")
        )
    }
}
