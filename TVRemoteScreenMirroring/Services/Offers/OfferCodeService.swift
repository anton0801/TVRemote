import Foundation

/// Client for the owner's offer-code service (contract in Documentation/OFFERS.md).
/// The app never contains the code pool or App Store Connect credentials.
struct OfferCodeService: Sendable {
    let baseURL: URL
    let campaignID: String
    let rulesVersion: String

    struct Availability: Decodable, Sendable {
        struct Sector: Decodable, Sendable {
            let id: String
            let plans: [String]
            let firstPeriodPrice: [String: String]?
        }
        let active: Bool
        let sectors: [Sector]
    }

    struct Reservation: Decodable, Sendable {
        let code: String
        let expiresAt: Date?
        let firstPeriodPrice: String?
    }

    /// Builds the endpoint URL; query items are added separately (a "?" in a path component would be escaped).
    func endpoint(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    private func request(_ path: String, query: [URLQueryItem] = [], method: String, body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: endpoint(path, query: query), timeoutInterval: 12)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 404: throw AppError.offerUnavailable
        case 409: throw AppError.offerAlreadyUsed
        case 410: throw AppError.offerExpired
        case 423: throw AppError.offerSoldOut
        default: throw AppError.offerServiceUnavailable
        }
    }

    /// Which sectors currently have codes (checked before the invitation is shown).
    func availability(storefront: String) async throws -> Availability {
        let data = try await request("v1/campaigns/\(campaignID)/availability", query: [URLQueryItem(name: "storefront", value: storefront)], method: "GET")
        return try JSONDecoder().decode(Availability.self, from: data)
    }

    /// Reserves (or returns the already reserved) one-time code for this result and plan.
    /// `resultID` is the idempotency key: retries and a second device session get the same code,
    /// and switching the plan swaps the reservation instead of creating a second bonus.
    func reserve(resultID: UUID, sectorID: String, plan: PurchasePlan, storefront: String, installationID: String) async throws -> Reservation {
        let data = try await request("v1/campaigns/\(campaignID)/reservations", method: "POST", body: [
            "resultId": resultID.uuidString,
            "sectorId": sectorID,
            "plan": plan.rawValue,
            "storefront": storefront,
            "rulesVersion": rulesVersion,
            "installationId": installationID,
        ])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Reservation.self, from: data)
    }
}
