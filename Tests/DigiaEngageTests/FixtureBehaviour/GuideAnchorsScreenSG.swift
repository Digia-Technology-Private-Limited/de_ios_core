import SwiftUI
@testable import DigiaEngage

/// Every anchor the guide fixtures target, at fixed positions: a search bar and wishlist button at
/// the top edge, category chips, a carousel, and a seller-info row lower down. Mirrors
/// `GuideAnchorsScreen` in `flutter/core/test/fixture_behaviour/support/ui_support.dart`.
///
/// Compiled into both test targets, as `SdkHarness.swift` is.
struct GuideAnchorsScreenSG: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                DigiaAnchor(anchorKey: "home_header_search") { target("Search", height: 44) }
                DigiaAnchor(anchorKey: "wishlist_icon_btn") { target("W", height: 44).frame(width: 44) }
            }
            Spacer().frame(height: 16)
            DigiaAnchor(anchorKey: "category_chips") { target("Categories", height: 40) }
            Spacer().frame(height: 140)
            DigiaAnchor(anchorKey: "home_carousel") { target("Carousel", height: 180) }
            Spacer().frame(height: 120)
            DigiaAnchor(anchorKey: "pdp_seller_info") { target("Seller info", height: 64) }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0xEC / 255, green: 0xEF / 255, blue: 0xF1 / 255))
    }

    private func target(_ label: String, height: CGFloat) -> some View {
        Color(red: 0x26 / 255, green: 0xA6 / 255, blue: 0x9A / 255)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .overlay(Text(label))
    }
}
