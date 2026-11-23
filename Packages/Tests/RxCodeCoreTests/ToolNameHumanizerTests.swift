import Testing
@testable import RxCodeCore

struct ToolNameHumanizerTests {
    @Test func repeatedCallsShareWorkAndDistinctToolsGenerateSerially() async {
        actor Generator {
            var identifiers: [String] = []
            var active = 0
            var peak = 0

            func generate(_ identifier: String) async -> String {
                identifiers.append(identifier)
                active += 1
                peak = max(peak, active)
                await Task.yield()
                active -= 1
                return "searching documents"
            }
        }
        let generator = Generator()
        let humanizer = ToolNameHumanizer { await generator.generate($0) }
        let names = ["mcp__drive__search", "mcp__wiki__search", "mcp__drive__search"]
        await withTaskGroup(of: String?.self) { group in
            for name in names {
                group.addTask { await humanizer.label(for: name) }
            }
            for await label in group { #expect(label == "Searching documents") }
        }
        #expect(await humanizer.label(for: names[0]) == "Searching documents")
        #expect(await generator.identifiers.sorted() == Array(Set(names)).sorted())
        #expect(await generator.peak == 1)
    }

    @Test func rejectsMalformedOutputAndNeverGeneratesFromArguments() async {
        let humanizer = ToolNameHumanizer { name in
            switch name {
            case "calendar__events": "Listing events\nAnother line"
            case "tasks__fetch": "Here is the label"
            case "files__search": nil
            default: "Listing events"
            }
        }
        #expect(await humanizer.label(for: "calendar__events") == nil)
        #expect(await humanizer.label(for: "tasks__fetch") == nil)
        #expect(await humanizer.label(for: "files__search") == nil)
        #expect(await humanizer.label(for: #"{"query":"private text"}"#) == nil)
        #expect(await humanizer.label(for: "external__list") == "Listing events")
    }
}
