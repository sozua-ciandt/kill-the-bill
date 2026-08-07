import Foundation

/// Authoritative Anthropic pricing, per https://www.anthropic.com/pricing
/// These override anything the models.dev catalog returns.
/// Cache write 5-min rate used; 1-hour rate ($6/$3.75 ratio) not distinguishable from logs.
enum CustomPricing {

    static let authoritative: [String: TokenPricing] = {
        var p: [String: TokenPricing] = [:]

        func add(_ keys: [String], input: Double, output: Double, cacheWrite: Double, cacheRead: Double) {
            let pricing = TokenPricing(input: input, output: output, cacheWrite: cacheWrite, cacheRead: cacheRead)
            for key in keys { p[key] = pricing }
        }

        // Claude Sonnet 4 / 4.6
        add(["claude-sonnet-4-6", "claude-sonnet-4", "claude-4-6-sonnet", "claude-4-sonnet"],
            input: 3.0, output: 15.0, cacheWrite: 3.75, cacheRead: 0.30)

        // Claude Opus 4 / 4.6 / 4.8
        add(["claude-opus-4-6", "claude-opus-4", "claude-4-6-opus", "claude-4-opus", "claude-opus-4-8"],
            input: 5.0, output: 25.0, cacheWrite: 6.25, cacheRead: 0.50)

        // Claude Sonnet 5
        add(["claude-sonnet-5"],
            input: 3.0, output: 15.0, cacheWrite: 3.75, cacheRead: 0.30)

        // Claude Opus 5
        add(["claude-opus-5"],
            input: 5.0, output: 25.0, cacheWrite: 6.25, cacheRead: 0.50)

        // Claude Haiku 4 / 4.5
        add(["claude-haiku-4-5", "claude-haiku-4"],
            input: 1.0, output: 5.0, cacheWrite: 1.25, cacheRead: 0.10)

        // Claude Sonnet 3.7 / 3.5
        add(["claude-sonnet-3-7", "claude-sonnet-3.7",
             "claude-sonnet-3-5", "claude-sonnet-3.5"],
            input: 3.0, output: 15.0, cacheWrite: 3.75, cacheRead: 0.30)

        // Claude Opus 3
        add(["claude-opus-3", "claude-3-opus"],
            input: 15.0, output: 75.0, cacheWrite: 18.75, cacheRead: 1.50)

        // Claude Haiku 3 / 3.5
        add(["claude-haiku-3-5", "claude-haiku-3.5",
             "claude-haiku-3", "claude-3-haiku"],
            input: 0.25, output: 1.25, cacheWrite: 0.30, cacheRead: 0.03)

        // OpenAI Codex / GPT-5.x — per https://openai.com/api/pricing
        // gpt-5.5 (Codex CLI default)
        add(["gpt-5.5", "gpt-5-5", "gpt-5.5-codex"],
            input: 5.0, output: 15.0, cacheWrite: 0, cacheRead: 1.25)

        // gpt-5.6 series (newer Codex)
        add(["gpt-5.6-sol", "gpt-5.6"],
            input: 5.0, output: 15.0, cacheWrite: 0, cacheRead: 1.25)

        // gpt-5 family
        add(["gpt-5", "gpt-5-chat"],
            input: 1.25, output: 10.0, cacheWrite: 0, cacheRead: 0)

        // gpt-5.1
        add(["gpt-5.1", "gpt-5-1"],
            input: 1.25, output: 10.0, cacheWrite: 0, cacheRead: 0)

        // gpt-5.4
        add(["gpt-5.4", "gpt-5-4"],
            input: 2.5, output: 15.0, cacheWrite: 0, cacheRead: 0)

        // gpt-5.4-mini
        add(["gpt-5.4-mini", "gpt-5-4-mini"],
            input: 0.75, output: 4.5, cacheWrite: 0, cacheRead: 0)

        // gpt-4.1
        add(["gpt-4.1", "gpt-4-1"],
            input: 2.0, output: 8.0, cacheWrite: 0, cacheRead: 0.50)

        // gpt-4o
        add(["gpt-4o"],
            input: 2.5, output: 10.0, cacheWrite: 0, cacheRead: 1.25)

        return p
    }()
}
