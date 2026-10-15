import Foundation
import Testing
@testable import IonKit

@Suite("JSONValue")
struct JSONValueTests {
    @Test func roundTripsEveryCase() throws {
        let value: JSONValue = [
            "null": nil, "bool": true, "int": 42, "double": 1.5, "string": "x",
            "array": [1, "two", [3]], "object": ["nested": ["deep": false]],
        ]
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
        #expect(decoded["int"]?.intValue == 42)
        #expect(decoded["double"]?.intValue == nil)
        #expect(decoded["array"]?[1]?.stringValue == "two")
        #expect(decoded["object"]?["nested"]?["deep"]?.boolValue == false)
        #expect(decoded["null"]?.isNull == true)
    }

    @Test func integersEncodeWithoutFraction() throws {
        let data = try JSONEncoder().encode(JSONValue.number(42))
        #expect(String(decoding: data, as: UTF8.self) == "42")
    }
}

@Suite("JSONAPIDocument")
struct DocumentTests {
    @Test func parsesSingleResourceFixture() throws {
        let document = try TestFixtures.document("person-single.synthetic")
        guard case .one(let object?) = document.data else {
            Issue.record("expected one resource")
            return
        }
        #expect(object.type == "person")
        #expect(object.id == "42")
        #expect(object.key == ResourceKey(type: "person", id: "42"))
        #expect(object.attributes["name"] == "Ann Example")
        #expect(object.attributes["legacyScore"]?.intValue == 7)
        #expect(object.relationships["tags"]?.data == .many([ResourceIdentifier(type: "tag", id: "7"), ResourceIdentifier(type: "tag", id: "9")]))
        #expect(object.relationships["tags"]?.links?.related?.href == "https://mock.ionkit.test/people/42/tags")
        #expect(object.relationships["group"]?.data == .one(nil))
        #expect(object.relationships["friends"]?.data == .many([]))
        #expect(object.links?.selfLink?.title == "Ann")
        #expect(object.meta?["revision"]?.intValue == 3)
        #expect(document.included.count == 2)
        #expect(document.included.map(\.id) == ["7", "9"])
        #expect(document.links?.selfLink?.href == "https://mock.ionkit.test/people/42")
        #expect(document.meta?["source"] == "synthetic")
        #expect(document.jsonapi?["version"] == "1.1")
        #expect(document.allObjects.count == 3)
    }

    @Test func parsesCollectionFixture() throws {
        let document = try TestFixtures.document("people-collection.synthetic")
        guard case .many(let objects) = document.data else {
            Issue.record("expected many resources")
            return
        }
        #expect(objects.map(\.id) == ["42", "43"])
        #expect(objects[1].attributes["birthday"] == .null)
        #expect(objects[1].relationships["group"]?.data == .one(ResourceIdentifier(type: "group", id: "3")))
        #expect(document.links?.next?.href == "https://mock.ionkit.test/people?page[number]=2&page[size]=2")
        #expect(document.links?.prev == nil)
        #expect(document.links?.all.count == 2)
        #expect(document.meta?["page"]?["total"]?.intValue == 5)
    }

    @Test func parsesErrorFixture() throws {
        let document = try TestFixtures.document("error-422.synthetic")
        let errors = try #require(document.errors)
        #expect(errors.count == 3)
        #expect(errors[0].id == "e1")
        #expect(errors[0].statusCode == 422)
        #expect(errors[0].code == "blank")
        #expect(errors[0].source?.pointer == "/data/attributes/name")
        #expect(errors[0].source?.attribute == "name")
        #expect(errors[0].meta?["field"] == "name")
        #expect(errors[1].source?.relationship == "group")
        #expect(errors[2].source == nil)
        #expect(document.data == nil)
    }

    @Test func emptyBodyIsEmptyDocument() throws {
        let document = try JSONAPIDocument.decode(try TestFixtures.data("empty-204.synthetic"))
        #expect(document.isEmpty)
        #expect(try JSONAPIDocument.decode(Data(" \n".utf8)).isEmpty)
    }

    @Test func nullPrimaryDataIsDistinctFromAbsent() throws {
        let null = try JSONAPIDocument.decode(Data(#"{"data": null}"#.utf8))
        #expect(null.data == .one(nil))
        let absent = try JSONAPIDocument.decode(Data(#"{"meta": {}}"#.utf8))
        #expect(absent.data == nil)
    }

    @Test(arguments: ["person-single.synthetic", "people-collection.synthetic", "error-422.synthetic"])
    func roundTrips(fixture: String) throws {
        let document = try TestFixtures.document(fixture)
        let encoded = try document.encoded()
        let decoded = try JSONAPIDocument.decode(encoded)
        #expect(decoded == document)
    }

    @Test func keepsUnknownTopLevelMembers() throws {
        let document = try JSONAPIDocument.decode(Data(#"{"data": [], "x-vendor": {"a": 1}}"#.utf8))
        #expect(document.extensions["x-vendor"]?["a"]?.intValue == 1)
        let reencoded = try JSONAPIDocument.decode(try document.encoded())
        #expect(reencoded == document)
    }

    @Test func linksParseBothForms() throws {
        let links = try JSONDecoder().decode(Links.self, from: Data(#"{"a": "https://x/a", "b": {"href": "https://x/b", "meta": {"n": 1}}, "c": null}"#.utf8))
        #expect(links["a"] == Link(href: "https://x/a"))
        #expect(links["b"]?.meta?["n"]?.intValue == 1)
        #expect(links["c"] == nil)
        let data = try JSONEncoder().encode(links)
        #expect(try JSONDecoder().decode(Links.self, from: data) == links)
    }
}
