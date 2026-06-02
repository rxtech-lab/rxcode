import Foundation
import RxCodeCore
import os

actor RateLimitService {

    static let shared = RateLimitService()

    private let logger = Logger(subsystem: "com.claudework", category: "RateLimitService")

    private struct OAuthTokens {
        let accessToken: String
        let refreshToken: String?
        let rawOauth: [String: Any]
    }

    private var cached: RateLimitUsage?
    private var cachedAt: Date?
    private var fetchTask: Task<RateLimitUsage?, Never>?
    private let cacheTTL: TimeInterval = 300  // 5 minutes
    private var authFailed = false

    /// In-memory copy of the Claude Code OAuth tokens. The
    /// `Claude Code-credentials` Keychain item is owned by the *Claude Code*
    /// app, not RxCode, so every read of it pops the macOS "wants to use
    /// confidential information" prompt once RxCode is re-signed (its signature
    /// is never on that item's ACL). Reading it once per launch and serving the
    /// rest from memory keeps that prompt to a single appearance. The network
    /// refresh updates this copy in place (we never write back to the Keychain),
    /// and it's cleared only when auth fails — so a credential the user freshly
    /// logged into Claude Code with is still picked up on the next poll.
    private var cachedTokens: OAuthTokens?

    func fetchUsage(forceRefresh: Bool = false) async -> RateLimitUsage? {
        if !forceRefresh, let c = cached, let at = cachedAt, Date().timeIntervalSince(at) < cacheTTL {
            return c
        }

        if let fetchTask {
            return await fetchTask.value ?? cached
        }

        let task = Task { await self.fetchUsageUncached(forceRefresh: forceRefresh) }
        fetchTask = task
        let usage = await task.value
        fetchTask = nil
        return usage ?? cached
    }

    private func fetchUsageUncached(forceRefresh: Bool) async -> RateLimitUsage? {
        if authFailed && !forceRefresh {
            return cached
        }

        guard let tokens = await readOAuthTokens() else {
            logger.debug("[RateLimit] OAuth token not found in Keychain")
            return cached
        }

        // If the token is expired, attempt to refresh it first
        let accessToken: String
        if isExpired(tokens.rawOauth) {
            logger.info("[RateLimit] Access token expired, attempting refresh...")
            if let refreshed = await refreshAccessToken(tokens) {
                accessToken = refreshed
            } else {
                logger.debug("[RateLimit] Token refresh failed, cannot fetch usage")
                authFailed = true
                cachedTokens = nil
                return cached
            }
        } else {
            accessToken = tokens.accessToken
        }

        logger.info("[RateLimit] Token ready, calling API...")

        guard let usage = await callAPI(token: accessToken) else {
            logger.debug("[RateLimit] API call returned nil")
            return cached
        }
        logger.info("[RateLimit] 5h=\(usage.fiveHourPercent)% 7d=\(usage.sevenDayPercent)%")

        authFailed = false
        cached = usage
        cachedAt = Date()
        return usage
    }

    // MARK: - Keychain

    private func readOAuthTokens() async -> OAuthTokens? {
        // Serve from memory whenever possible — see `cachedTokens`. Only the
        // first miss (or the first poll after an auth failure cleared it)
        // touches the foreign Keychain item that triggers the prompt.
        if let cachedTokens { return cachedTokens }

        guard let raw = await MainActor.run(body: { KeychainHelper.readString(service: "Claude Code-credentials") }) else {
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String
        else { return nil }

        let refreshToken = oauth["refreshToken"] as? String
        let tokens = OAuthTokens(accessToken: accessToken, refreshToken: refreshToken, rawOauth: oauth)
        cachedTokens = tokens
        return tokens
    }

    private func isExpired(_ oauth: [String: Any]) -> Bool {
        guard let expiresAt = oauth["expiresAt"] else { return false }

        var expiryDate: Date?
        if let ms = expiresAt as? Double {
            let seconds = ms > 1e10 ? ms / 1000 : ms
            expiryDate = Date(timeIntervalSince1970: seconds)
        } else if let str = expiresAt as? String {
            expiryDate = Self.isoFormatter.date(from: str) ?? Self.isoFormatterFallback.date(from: str)
        }
        guard let expiry = expiryDate else { return false }
        // Consider expired 30 seconds before the actual expiry
        return Date() >= expiry.addingTimeInterval(-30)
    }

    // MARK: - Token Refresh

    private func refreshAccessToken(_ tokens: OAuthTokens) async -> String? {
        guard let refreshToken = tokens.refreshToken else {
            logger.debug("[RateLimit] No refresh token available")
            return nil
        }

        guard let url = URL(string: "https://api.anthropic.com/api/oauth/token") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 10

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                logger.debug("[RateLimit] Token refresh returned status \(code)")
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccessToken = json["access_token"] as? String
            else {
                logger.debug("[RateLimit] Token refresh response parse failed")
                return nil
            }

            logger.info("[RateLimit] Token refreshed successfully")
            // Skip Keychain write since account is unknown — update the
            // in-memory copy instead. Refresh the stored `expiresAt` from the
            // response's `expires_in` (seconds) so the next poll doesn't treat
            // the just-refreshed token as expired and refresh again; drop it if
            // the server didn't say, which makes `isExpired` return false.
            var updatedOauth = tokens.rawOauth
            if let expiresIn = json["expires_in"] as? Double {
                updatedOauth["expiresAt"] = (Date().timeIntervalSince1970 + expiresIn) * 1000
            } else {
                updatedOauth.removeValue(forKey: "expiresAt")
            }
            let newRefreshToken = (json["refresh_token"] as? String) ?? tokens.refreshToken
            cachedTokens = OAuthTokens(
                accessToken: newAccessToken,
                refreshToken: newRefreshToken,
                rawOauth: updatedOauth
            )
            return newAccessToken
        } catch {
            logger.debug("[RateLimit] Token refresh error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - API

    private func callAPI(token: String) async -> RateLimitUsage? {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                if code == 401 {
                    logger.debug("[RateLimit] API returned 401 — token invalid")
                    authFailed = true
                    cachedTokens = nil
                } else {
                    logger.warning("[RateLimit] API returned status \(code)")
                }
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            let fiveHour = json["five_hour"] as? [String: Any]
            let sevenDay = json["seven_day"] as? [String: Any]

            return RateLimitUsage(
                fiveHourPercent: (fiveHour?["utilization"] as? Double) ?? 0,
                sevenDayPercent: (sevenDay?["utilization"] as? Double) ?? 0,
                fiveHourResetsAt: parseISO8601(fiveHour?["resets_at"] as? String),
                sevenDayResetsAt: parseISO8601(sevenDay?["resets_at"] as? String)
            )
        } catch {
            logger.error("Rate limit fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatterFallback = ISO8601DateFormatter()

    private func parseISO8601(_ str: String?) -> Date? {
        guard let str else { return nil }
        return Self.isoFormatter.date(from: str) ?? Self.isoFormatterFallback.date(from: str)
    }
}
