import Foundation

/// One ad lifecycle step (docs/sdk/ADS_ATTRIBUTION_CONTRACT.md). Build one by
/// hand or with a mediation adapter, then send it with RavensightClient.trackAd.
public struct RavensightAd: Equatable {
    /// The formats the server reads.
    public static let formats = ["banner", "interstitial", "rewarded", "native", "app_open", "other"]
    /// The lifecycle steps the server reads.
    public static let results = ["shown", "clicked", "failed", "rewarded"]

    /// The network that served the ad: admob, applovin, ironsource, ...
    public var network: String
    /// One of formats.
    public var format: String
    /// One of results.
    public var result: String
    /// The game's own placement name. Nil or empty is not sent.
    public var placement: String?
    /// Revenue of this impression in micros of currency, as a digit string
    /// ("1500" is 0.0015). Only on a shown result.
    public var revenueMicros: String?
    /// ISO 4217, three letters. Required with revenueMicros.
    public var currency: String?

    public init(network: String, format: String, result: String, placement: String? = nil,
                revenueMicros: String? = nil, currency: String? = nil) {
        self.network = network
        self.format = format
        self.result = result
        self.placement = placement
        self.revenueMicros = revenueMicros
        self.currency = currency
    }

    // MARK: Revenue arithmetic

    /// "0.0015" to "1500": decimal text in major units to whole micros,
    /// rounding half up past the sixth decimal, on the digits only. Nil when
    /// the text is not a plain non-negative decimal or the result has more
    /// than 18 digits.
    public static func microsFromDecimalString(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2, let whole = pieces.first, !whole.isEmpty,
              whole.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        var fraction = pieces.count == 2 ? String(pieces[1]) : ""
        guard pieces.count == 1 || !fraction.isEmpty,
              fraction.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let roundUp = fraction.count > 6 && fraction[fraction.index(fraction.startIndex, offsetBy: 6)] >= "5"
        fraction = String((fraction + "000000").prefix(6))
        var digits = Array(String(whole) + fraction)
        if roundUp {
            var index = digits.count - 1
            while index >= 0 && digits[index] == "9" {
                digits[index] = "0"
                index -= 1
            }
            if index < 0 { digits.insert("1", at: 0) } else {
                digits[index] = Character(String(digits[index].wholeNumberValue! + 1))
            }
        }
        var result = String(digits).drop { $0 == "0" }
        if result.isEmpty { result = "0" }
        return result.count > 18 ? nil : String(result)
    }

    /// A mediation callback's revenue double in major units to micros:
    /// formatted with 15 significant digits, the most a double always holds
    /// exactly, then converted on the digits. Never multiplies the double.
    public static func microsFromDouble(_ value: Double) -> String? {
        guard value >= 0, value <= 1e12, value.isFinite else { return nil }
        let sci = String(format: "%.14e", value)
        let parts = sci.split(separator: "e")
        guard parts.count == 2, let exponent = Int(parts[1]) else { return nil }
        let mantissa = parts[0].replacingOccurrences(of: ".", with: "")
        let decimal: String
        if exponent < 0 {
            decimal = "0." + String(repeating: "0", count: -exponent - 1) + mantissa
        } else {
            let point = exponent + 1
            if mantissa.count <= point {
                decimal = mantissa + String(repeating: "0", count: point - mantissa.count)
            } else {
                let cut = mantissa.index(mantissa.startIndex, offsetBy: point)
                decimal = mantissa[..<cut] + "." + mantissa[cut...]
            }
        }
        return microsFromDecimalString(decimal)
    }

    /// A mediation SDK's format label to one of formats; unknown is "other".
    public static func mapFormat(_ label: String) -> String {
        let key = label.trimmingCharacters(in: .whitespaces).uppercased()
            .replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        switch key {
        case "BANNER", "MREC", "LEADER", "LEADERBOARD": return "banner"
        case "INTER", "INTERSTITIAL": return "interstitial"
        case "REWARDED", "REWARDED_VIDEO", "REWARDEDVIDEO", "REWARDED_INTER", "REWARDED_INTERSTITIAL": return "rewarded"
        case "NATIVE": return "native"
        case "APP_OPEN", "APPOPEN", "SPLASH": return "app_open"
        default: return "other"
        }
    }

    // MARK: Mediation adapters
    //
    // Each takes the values a mediation SDK's impression-level revenue
    // callback reports, so this package never links that SDK, and returns a
    // shown ad with revenue.

    /// AdMob paid event (GADAdValue): value is already micros.
    public static func fromAdMob(valueMicros: Int64, currencyCode: String, adSourceName: String?,
                                 format: String, placement: String?) -> RavensightAd {
        let source = adSourceName?.trimmingCharacters(in: .whitespaces) ?? ""
        return RavensightAd(network: source.isEmpty ? "admob" : source, format: mapFormat(format), result: "shown",
                            placement: placement, revenueMicros: valueMicros >= 0 ? String(valueMicros) : nil,
                            currency: currencyCode.uppercased())
    }

    /// AppLovin MAX didPayRevenue (MAAd): revenue in USD major units.
    public static func fromAppLovinMax(revenue: Double, networkName: String, format: String,
                                       placement: String?) -> RavensightAd {
        return RavensightAd(network: networkName, format: mapFormat(format), result: "shown", placement: placement,
                            revenueMicros: microsFromDouble(revenue), currency: "USD")
    }

    /// ironSource LevelPlay impressionDataDidSucceed (ISImpressionData):
    /// revenue in USD major units.
    public static func fromIronSource(revenue: Double, adNetwork: String, adUnit: String,
                                      placement: String?) -> RavensightAd {
        return RavensightAd(network: adNetwork, format: mapFormat(adUnit), result: "shown", placement: placement,
                            revenueMicros: microsFromDouble(revenue), currency: "USD")
    }

    /// TopOn revenue or show callback (ATAdInfo): publisher revenue in major
    /// units of currency.
    public static func fromTopOn(publisherRevenue: Double, currency: String, networkName: String,
                                 adType: String, placement: String?) -> RavensightAd {
        return RavensightAd(network: networkName, format: mapFormat(adType), result: "shown", placement: placement,
                            revenueMicros: microsFromDouble(publisherRevenue), currency: currency.uppercased())
    }

    /// The event data, or nil when the ad breaks the contract (refused
    /// locally): no network, an unknown format or result, a revenue that is
    /// not a digit string, revenue without a three letter currency, or
    /// revenue on a result other than shown.
    func eventData() -> [String: Any]? {
        let network = self.network.trimmingCharacters(in: .whitespaces)
        let placement = self.placement?.trimmingCharacters(in: .whitespaces) ?? ""
        let currency = self.currency?.trimmingCharacters(in: .whitespaces).uppercased() ?? ""
        let revenue = revenueMicros ?? ""
        guard !network.isEmpty, network.utf16.count <= 64,
              RavensightAd.formats.contains(format), RavensightAd.results.contains(result),
              placement.utf16.count <= 100 else { return nil }
        var data: [String: Any] = [
            "rs_kind": "ad", "rs_ad_network": network, "rs_ad_format": format, "rs_ad_result": result,
        ]
        if !placement.isEmpty { data["rs_ad_placement"] = placement }
        if !revenue.isEmpty {
            let digits = revenue.count <= 18 && revenue.allSatisfy { $0.isASCII && $0.isNumber }
            let iso = currency.count == 3 && currency.allSatisfy { $0.isASCII && $0.isUppercase }
            guard digits, iso, result == "shown" else { return nil }
            data["rs_revenue_micros"] = revenue
            data["rs_currency"] = currency
        }
        return data
    }
}

/// Where this install was acquired. Sent once per install.
public struct RavensightAttribution: Equatable {
    /// utm, store_referrer, organic, or a partner name. Required.
    public var source: String
    public var network: String?
    public var campaign: String?
    public var adset: String?
    public var creative: String?
    /// When the player clicked or opened the link.
    public var touchTime: Date?

    public init(source: String, network: String? = nil, campaign: String? = nil, adset: String? = nil,
                creative: String? = nil, touchTime: Date? = nil) {
        self.source = source
        self.network = network
        self.campaign = campaign
        self.adset = adset
        self.creative = creative
        self.touchTime = touchTime
    }

    func eventData() -> [String: Any]? {
        let source = self.source.trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty, source.utf16.count <= 64 else { return nil }
        var data: [String: Any] = ["rs_kind": "attribution", "rs_attr_source": source]
        for (key, value, max) in [("rs_attr_network", network, 100), ("rs_campaign", campaign, 200),
                                  ("rs_adset", adset, 200), ("rs_creative", creative, 200)] {
            let trimmed = value?.trimmingCharacters(in: .whitespaces) ?? ""
            if trimmed.isEmpty { continue }
            guard trimmed.utf16.count <= max else { return nil }
            data[key] = trimmed
        }
        if let touch = touchTime { data["rs_touch_time"] = Int64(touch.timeIntervalSince1970 * 1000) }
        return data
    }
}
