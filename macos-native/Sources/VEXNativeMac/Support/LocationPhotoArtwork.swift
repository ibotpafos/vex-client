import Foundation

enum LocationPhotoArtwork {
    static func assetName(countryCode: String) -> String? {
        switch countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "DE":
            return "location-frankfurt-de"
        case "FI":
            return "location-helsinki-fi"
        case "NL":
            return "location-amsterdam-nl"
        default:
            return nil
        }
    }
}
