import Testing
@testable import ParseleyCore

@Suite("JSON parsing")
struct JSONValueTests {
    @Test func keepsKeyOrderAndExactNumbers() throws {
        let value = try JSONValue.parse(#"{"z": 1.10, "a": 12345678901234567890, "m": -0.5e-3}"#)
        #expect(value == .object([
            JSONMember("z", .number("1.10")),
            JSONMember("a", .number("12345678901234567890")),
            JSONMember("m", .number("-0.5e-3")),
        ]))
    }

    @Test func parsesAllValueKinds() throws {
        let value = try JSONValue.parse(#" [true, false, null, "x", {}, [], 0] "#)
        #expect(value == .array([.bool(true), .bool(false), .null, .string("x"), .object([]), .array([]), .number("0")]))
    }

    @Test func decodesEscapes() throws {
        #expect(try JSONValue.parse(#""a\"b\\c\/d\n\té😀""#) == .string("a\"b\\c/d\n\té😀"))
    }

    @Test func reportsLineAndColumn() {
        do {
            _ = try JSONValue.parse("{\n  \"a\": 1,\n  \"b\" 2\n}")
            Issue.record("should have failed")
        } catch let error as JSONParseError {
            #expect(error.line == 3)
            #expect(error.column == 7)
            #expect(error.message.contains("':'"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test(arguments: ["", "{", "[1,]", "{\"a\":}", "01", "1.", "tru", "\"unterminated", "{} x", "{'a': 1}", "[1 2]"])
    func rejectsInvalidJSON(_ text: String) {
        #expect(throws: JSONParseError.self) { try JSONValue.parse(text) }
    }

    @Test func limitsNesting() {
        let deep = String(repeating: "[", count: 600) + String(repeating: "]", count: 600)
        #expect(throws: JSONParseError.self) { try JSONValue.parse(deep) }
        #expect((try? JSONValue.parse(deep, maxDepth: 1_000)) != nil)
    }

    @Test func roundTripsThroughSerialization() throws {
        let text = #"{"name":"Ana \"A\"","tags":["x",1,true,null],"nested":{"empty":{},"list":[]}}"#
        let value = try JSONValue.parse(text)
        #expect(value.serialized(pretty: false) == text)
        #expect(try JSONValue.parse(value.serialized(pretty: true)) == value)
        #expect(value.serialized().contains("\n  \"tags\": [\n    \"x\","))
    }
}

@Suite("JSON graph")
struct JSONGraphTests {
    let sample = try! JSONValue.parse("""
    {"name": "Ana", "age": 31, "address": {"city": "Lisbon", "zip": "1000"},
     "orders": [{"id": 1, "total": 19.5}, {"id": 2, "total": 7}], "tags": ["a", "b"], "vip": true}
    """)

    @Test func buildsCardsAndEdges() {
        let graph = JSONGraph(sample)
        // root, address, orders, orders[0], orders[1], tags, tags[0], tags[1]
        #expect(graph.nodes.count == 8)
        let root = graph.nodes[0]
        #expect(root.kind == .object)
        #expect(root.rows.map(\.key) == ["name", "age", "address", "orders", "tags", "vip"])
        #expect(root.rows[0].value == "\"Ana\"")
        #expect(root.rows[1].kind == .number)
        #expect(root.rows[2].value == "{2 keys}")
        #expect(root.rows[3].value == "[2 items]")
        #expect(root.childCount == 3)

        let paths = graph.nodes.map(\.path)
        #expect(paths == ["$", "$.address", "$.orders", "$.orders[0]", "$.orders[1]", "$.tags", "$.tags[0]", "$.tags[1]"])
        #expect(graph.edges.contains(JSONGraph.Edge(from: 0, to: 1, label: "address")))
        #expect(graph.edges.contains(JSONGraph.Edge(from: 2, to: 3, label: "0")))
        #expect(graph.nodes[6].kind == .value)
        #expect(graph.nodes[6].rows[0].value == "\"a\"")
    }

    @Test func layoutHasNoOverlapsAndFlowsRight() {
        let graph = JSONGraph(sample)
        for a in graph.nodes {
            for b in graph.nodes where b.id > a.id {
                #expect(!a.frame.intersects(b.frame), "\(a.path) overlaps \(b.path)")
            }
            if let parent = a.parent {
                #expect(a.frame.x > graph.nodes[parent].frame.maxX)
            }
        }
        #expect(graph.size.width >= graph.nodes.map(\.frame.maxX).max()!)
    }

    @Test func collapsingHidesChildren() {
        let graph = JSONGraph(sample, collapsed: ["$.orders"])
        #expect(!graph.nodes.contains { $0.path.hasPrefix("$.orders[") })
        let orders = graph.nodes.first { $0.path == "$.orders" }!
        #expect(orders.isCollapsed)
        #expect(orders.childCount == 2)
    }

    @Test func capsHugeDocuments() throws {
        let big = try JSONValue.parse("[" + (0..<5_000).map { "{\"i\":\($0)}" }.joined(separator: ",") + "]")
        let graph = JSONGraph(big, maxNodes: 100)
        #expect(graph.isTruncated)
        #expect(graph.nodes.count <= 101)
        #expect(graph.nodes.last?.kind == .more)
        #expect(graph.nodes.last?.rows.first?.value.contains("more") == true)
    }

    @Test func shortensLongValues() throws {
        let long = String(repeating: "x", count: 200)
        let graph = JSONGraph(try JSONValue.parse("{\"note\": \"\(long)\"}"))
        let value = graph.nodes[0].rows[0].value
        #expect(value.count == JSONGraph.maxValueLength)
        #expect(value.hasSuffix("…"))
    }

    @Test func searchFindsKeysValuesAndTitles() {
        let graph = JSONGraph(sample)
        #expect(graph.search("lisbon") == [1])
        #expect(graph.search("total") == [3, 4])
        #expect(graph.search("  ") == [])
    }

    @Test func pathsResolveBackToValues() throws {
        let doc = try JSONValue.parse(#"{"odd key": {"a.b": [10, {"x": "y"}]}}"#)
        let graph = JSONGraph(doc)
        let deepest = graph.nodes.first { $0.rows.contains { $0.key == "x" } }!
        #expect(deepest.path == #"$["odd key"]["a.b"][1]"#)
        #expect(JSONGraph.value(at: deepest.path, in: doc) == .object([JSONMember("x", .string("y"))]))
        #expect(JSONGraph.value(at: "$", in: doc) == doc)
        #expect(JSONGraph.value(at: "$.missing", in: doc) == nil)
    }

    @Test func primitiveRootIsASingleCard() throws {
        let graph = JSONGraph(try JSONValue.parse("42"))
        #expect(graph.nodes.count == 1)
        #expect(graph.nodes[0].kind == .value)
        #expect(graph.edges.isEmpty)
    }
}
