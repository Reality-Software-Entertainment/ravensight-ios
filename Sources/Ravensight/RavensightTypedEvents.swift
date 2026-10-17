import Foundation

/// Builds the reserved rs_* property sets for the typed events. Pure: no
/// client, no I/O. Every builder merges the caller's extra properties first,
/// so the reserved keys win, and never throws or validates beyond what the
/// contract says the helper does: a wrong amount is passed through and the
/// server flags the event.
enum RavensightTypedEvents {
    static let maxMessageChars = 200
    static let maxStackChars = 2000

    typealias Built = (name: String, data: [String: Any])

    private static func merged(_ extra: [String: Any]?, _ reserved: [String: Any]) -> [String: Any] {
        var data = extra ?? [:]
        for (key, value) in reserved { data[key] = value }
        return data
    }

    /// Cuts to a number of characters, never inside a character.
    static func cut(_ text: String, _ limit: Int) -> String {
        return text.count > limit ? String(text.prefix(limit)) : text
    }

    /// amount is an Int or a digit String (Any so both overloads share this).
    static func purchase(
        amount: Any, currency: String, itemType: String, itemId: String,
        cart: String?, transactionId: String?, name: String?, extra: [String: Any]?
    ) -> Built {
        var reserved: [String: Any] = [
            "rs_kind": "purchase",
            "rs_amount": amount,
            "rs_currency": currency.uppercased(),
            "rs_item_type": itemType,
            "rs_item_id": itemId,
        ]
        if let cart = cart { reserved["rs_cart"] = cart }
        if let transactionId = transactionId { reserved["rs_transaction_id"] = transactionId }
        return (name ?? "purchase", merged(extra, reserved))
    }

    static func resource(
        flow: String, resource: String, amount: Double, itemType: String?, itemId: String?,
        name: String?, extra: [String: Any]?
    ) -> Built {
        var reserved: [String: Any] = [
            "rs_kind": "resource",
            "rs_flow": flow,
            "rs_resource": resource,
            "rs_amount": amount,
        ]
        if let itemType = itemType { reserved["rs_item_type"] = itemType }
        if let itemId = itemId { reserved["rs_item_id"] = itemId }
        // An unknown flow still sends, flagged by the server; its name falls
        // back to the source default.
        return (name ?? (flow == "sink" ? "resource_sink" : "resource_source"), merged(extra, reserved))
    }

    static func progression(
        status: String, p1: String, p2: String?, p3: String?, score: Double?,
        name: String?, extra: [String: Any]?
    ) -> Built {
        var reserved: [String: Any] = [
            "rs_kind": "progression",
            "rs_status": status,
            "rs_p1": p1,
        ]
        if let p2 = p2 { reserved["rs_p2"] = p2 }
        if let p3 = p3 { reserved["rs_p3"] = p3 }
        if let score = score { reserved["rs_score"] = score }
        let known = ["start", "complete", "fail"].contains(status) ? status : "start"
        return (name ?? "progression_\(known)", merged(extra, reserved))
    }

    static func error(
        severity: String, message: String, stack: String?, name: String?, extra: [String: Any]?
    ) -> Built {
        var reserved: [String: Any] = [
            "rs_kind": "error",
            "rs_severity": severity,
            "rs_message": cut(message, maxMessageChars),
        ]
        if let stack = stack { reserved["rs_stack"] = cut(stack, maxStackChars) }
        return (name ?? "error", merged(extra, reserved))
    }

    static func health(fpsMedian: Double, fpsP10: Double, memoryMb: Double?, bootMs: Double?) -> Built {
        var data: [String: Any] = [
            "rs_kind": "health",
            "rs_fps_median": fpsMedian,
            "rs_fps_p10": fpsP10,
        ]
        if let memoryMb = memoryMb { data["rs_memory_mb"] = memoryMb }
        if let bootMs = bootMs { data["rs_boot_ms"] = bootMs }
        return ("health", data)
    }
}

extension Ravensight {
    /// A purchase, in whole minor units of the currency (499 is 4.99 USD).
    /// The currency is upper-cased. Returns what track returns.
    @discardableResult
    public static func trackPurchase(
        amount: Int, currency: String, itemType: String, itemId: String,
        cart: String? = nil, transactionId: String? = nil,
        name: String? = nil, extra: [String: Any]? = nil
    ) -> Bool {
        let built = RavensightTypedEvents.purchase(
            amount: amount, currency: currency, itemType: itemType, itemId: itemId,
            cart: cart, transactionId: transactionId, name: name, extra: extra)
        return track(built.name, data: built.data)
    }

    /// A purchase with the amount as a digit string (for amounts held as text).
    @discardableResult
    public static func trackPurchase(
        amount: String, currency: String, itemType: String, itemId: String,
        cart: String? = nil, transactionId: String? = nil,
        name: String? = nil, extra: [String: Any]? = nil
    ) -> Bool {
        let built = RavensightTypedEvents.purchase(
            amount: amount, currency: currency, itemType: itemType, itemId: itemId,
            cart: cart, transactionId: transactionId, name: name, extra: extra)
        return track(built.name, data: built.data)
    }

    /// A resource flow: flow is "source" (gained) or "sink" (spent).
    @discardableResult
    public static func trackResource(
        flow: String, resource: String, amount: Double,
        itemType: String? = nil, itemId: String? = nil,
        name: String? = nil, extra: [String: Any]? = nil
    ) -> Bool {
        let built = RavensightTypedEvents.resource(
            flow: flow, resource: resource, amount: amount, itemType: itemType,
            itemId: itemId, name: name, extra: extra)
        return track(built.name, data: built.data)
    }

    /// A progression step: status is "start", "complete" or "fail".
    @discardableResult
    public static func trackProgression(
        status: String, p1: String, p2: String? = nil, p3: String? = nil,
        score: Double? = nil, name: String? = nil, extra: [String: Any]? = nil
    ) -> Bool {
        let built = RavensightTypedEvents.progression(
            status: status, p1: p1, p2: p2, p3: p3, score: score, name: name, extra: extra)
        return track(built.name, data: built.data)
    }

    /// An error: severity is "debug", "info", "warning", "error" or
    /// "critical". The message is cut to 200 characters, the stack to 2000.
    @discardableResult
    public static func trackError(
        severity: String, message: String, stack: String? = nil,
        name: String? = nil, extra: [String: Any]? = nil
    ) -> Bool {
        let built = RavensightTypedEvents.error(
            severity: severity, message: message, stack: stack, name: name, extra: extra)
        return track(built.name, data: built.data)
    }
}
