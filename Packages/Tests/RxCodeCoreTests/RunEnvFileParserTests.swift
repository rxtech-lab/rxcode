import Foundation
import Testing
@testable import RxCodeCore

@Suite(".env file parser")
struct RunEnvFileParserTests {

    @Test("Parses KEY=VALUE")
    func basicKeyValue() {
        let pairs = RunEnvFileParser.parse("FOO=bar\nBAZ=qux")
        #expect(pairs.count == 2)
        #expect(pairs[0].key == "FOO")
        #expect(pairs[0].value == "bar")
        #expect(pairs[1].key == "BAZ")
        #expect(pairs[1].value == "qux")
    }

    @Test("Skips blank lines and comments")
    func skipsBlanksAndComments() {
        let input = """
        # a comment
        FOO=1

        # another
        BAR=2
        """
        let pairs = RunEnvFileParser.parse(input)
        #expect(pairs.map(\.key) == ["FOO", "BAR"])
    }

    @Test("Unwraps double-quoted values and applies escapes")
    func doubleQuoted() {
        let input = #"GREETING="hello\nworld"\#nPATH="\"quoted\"""#
        let dict = RunEnvFileParser.parseAsDictionary(input)
        #expect(dict["GREETING"] == "hello\nworld")
        #expect(dict["PATH"] == "\"quoted\"")
    }

    @Test("Single-quoted values are taken verbatim (no escapes)")
    func singleQuoted() {
        let input = "X='literal \\n value'"
        let dict = RunEnvFileParser.parseAsDictionary(input)
        #expect(dict["X"] == "literal \\n value")
    }

    @Test("Inline # in unquoted value is preserved")
    func inlineHashKept() {
        let dict = RunEnvFileParser.parseAsDictionary("URL=http://example.com/#anchor")
        #expect(dict["URL"] == "http://example.com/#anchor")
    }

    @Test("export prefix is stripped")
    func exportPrefix() {
        let dict = RunEnvFileParser.parseAsDictionary("export FOO=bar")
        #expect(dict["FOO"] == "bar")
    }

    @Test("Trims surrounding whitespace")
    func trimsWhitespace() {
        let dict = RunEnvFileParser.parseAsDictionary("   FOO  =  bar  ")
        #expect(dict["FOO"] == "bar")
    }

    @Test("Last duplicate key wins in dictionary form")
    func duplicateKeyLastWins() {
        let dict = RunEnvFileParser.parseAsDictionary("X=1\nX=2\nX=3")
        #expect(dict["X"] == "3")
    }

    @Test("Returns ordered pairs preserving duplicates")
    func orderedPairsKeepDuplicates() {
        let pairs = RunEnvFileParser.parse("X=1\nX=2")
        #expect(pairs.count == 2)
        #expect(pairs[0].value == "1")
        #expect(pairs[1].value == "2")
    }
}
