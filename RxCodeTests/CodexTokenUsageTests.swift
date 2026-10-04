import RxCodeCore
import XCTest
@testable import RxCode

/// Codex's `turn/completed` carries no usage, so per-turn tokens must come from
/// the cumulative `thread/tokenUsage/updated` snapshots. Without this the
/// briefing token-usage panel never counted Codex turns.
final class CodexTokenUsageTests: XCTestCase {

    private func breakdown(input: Int, cached: Int, output: Int, reasoning: Int = 0) -> JSONValue {
        .object([
            "totalTokens": .number(Double(input + output)),
            "inputTokens": .number(Double(input)),
            "cachedInputTokens": .number(Double(cached)),
            "outputTokens": .number(Double(output)),
            "reasoningOutputTokens": .number(Double(reasoning)),
        ])
    }

    private func params(total: JSONValue, last: JSONValue) -> [String: JSONValue] {
        [
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "tokenUsage": .object([
                "total": total,
                "last": last,
                "modelContextWindow": .number(272_000),
            ]),
        ]
    }

    func testBreakdownSplitsCachedInputAndDoesNotDoubleCountReasoning() throws {
        let parsed = try XCTUnwrap(CodexAppServer.tokenUsageBreakdowns(from: params(
            total: breakdown(input: 1_000, cached: 800, output: 150, reasoning: 50),
            last: breakdown(input: 1_000, cached: 800, output: 150, reasoning: 50)
        )))
        XCTAssertEqual(parsed.total.inputTokens, 200)
        XCTAssertEqual(parsed.total.cacheReadInputTokens, 800)
        XCTAssertEqual(parsed.total.outputTokens, 150)
        XCTAssertEqual(parsed.total.cacheCreationInputTokens, 0)
    }

    func testTurnUsageIsDeltaFromPreTurnBaseline() throws {
        // Earlier turns already accrued 5,000 input (4,000 cached) / 300 output.
        let first = try XCTUnwrap(CodexAppServer.tokenUsageBreakdowns(from: params(
            total: breakdown(input: 6_000, cached: 4_500, output: 400),
            last: breakdown(input: 1_000, cached: 500, output: 100)
        )))
        let baseline = try XCTUnwrap(CodexAppServer.usageDelta(from: first.last, to: first.total))
        let second = try XCTUnwrap(CodexAppServer.tokenUsageBreakdowns(from: params(
            total: breakdown(input: 7_500, cached: 5_500, output: 600),
            last: breakdown(input: 1_500, cached: 1_000, output: 200)
        )))

        let turn = try XCTUnwrap(CodexAppServer.usageDelta(from: baseline, to: second.total))
        XCTAssertEqual(turn.inputTokens, 1_000)
        XCTAssertEqual(turn.cacheReadInputTokens, 1_500)
        XCTAssertEqual(turn.outputTokens, 300)
    }

    func testUsageDeltaIsNilWhenNothingAccrued() {
        let usage = CodexAppServer.codexUsageBreakdown([
            "inputTokens": .number(10), "outputTokens": .number(5),
        ])
        XCTAssertNil(CodexAppServer.usageDelta(from: usage, to: usage))
    }
}
