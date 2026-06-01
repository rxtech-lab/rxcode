import Testing
@testable import RxCodeCore

@Suite("GitHubRulesetSummary.validate")
struct GitHubRulesetSummaryTests {

    private let validRuleset = """
    {
      "name": "main protection",
      "target": "branch",
      "enforcement": "active",
      "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
      "rules": [
        { "type": "deletion" },
        { "type": "required_linear_history" }
      ]
    }
    """

    @Test("valid ruleset parses with summary fields")
    func validParses() throws {
        let result = GitHubRulesetSummary.validate(rawJSON: validRuleset)
        let summary = try result.get()
        #expect(summary.name == "main protection")
        #expect(summary.target == "branch")
        #expect(summary.enforcement == "active")
        #expect(summary.ruleCount == 2)
    }

    @Test("whitespace is tolerated")
    func whitespaceTolerated() throws {
        let result = GitHubRulesetSummary.validate(rawJSON: "\n\n  " + validRuleset + "  \n")
        #expect((try? result.get()) != nil)
    }

    @Test("empty input fails as empty")
    func emptyFails() {
        let result = GitHubRulesetSummary.validate(rawJSON: "   \n  ")
        guard case .failure(let error) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(error == .empty)
    }

    @Test("malformed JSON fails")
    func malformedFails() {
        let result = GitHubRulesetSummary.validate(rawJSON: "{ not json ")
        guard case .failure(let error) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(error == .invalidJSON)
    }

    @Test("non-object JSON fails")
    func nonObjectFails() {
        let result = GitHubRulesetSummary.validate(rawJSON: "[1, 2, 3]")
        guard case .failure(let error) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(error == .notAnObject)
    }

    @Test("missing required fields are reported")
    func missingFieldsReported() {
        // Missing `enforcement` and `rules`.
        let json = """
        { "name": "x", "target": "branch" }
        """
        let result = GitHubRulesetSummary.validate(rawJSON: json)
        guard case .failure(.missingFields(let fields)) = result else {
            Issue.record("expected missingFields failure")
            return
        }
        #expect(fields.contains("enforcement"))
        #expect(fields.contains("rules"))
        #expect(!fields.contains("name"))
    }

    @Test("rules of wrong type counts as missing")
    func rulesWrongType() {
        let json = """
        { "name": "x", "target": "branch", "enforcement": "active", "rules": "nope" }
        """
        let result = GitHubRulesetSummary.validate(rawJSON: json)
        guard case .failure(.missingFields(let fields)) = result else {
            Issue.record("expected missingFields failure")
            return
        }
        #expect(fields == ["rules"])
    }
}
