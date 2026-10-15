import Foundation
import Testing
@testable import IonKit

@Suite("ResourceCodec")
struct ResourceCodecTests {
    let codec = ResourceCodec.default

    @Test func decodesPersonFromFixture() throws {
        let document = try TestFixtures.document("person-single.synthetic")
        let object = try #require(document.data?.objects.first)
        let person: Person = try codec.decode(object)
        #expect(person.id == "42")
        #expect(person.name == "Ann Example")
        #expect(person.notes == "Likes tea")
        #expect(person.tags == .ids(["7", "9"]))
        #expect(person.group == .null)
        #expect(person.friends == .ids([]))
        #expect(person.initials == "AE")
        let updated = try #require(person.updatedAt)
        #expect(abs(updated.timeIntervalSince1970 - 1_792_058_400.123) < 0.001)
        let birthday = try #require(person.birthday)
        #expect(ISO8601.format(birthday) == "1990-05-04T00:00:00.000Z")
    }

    @Test func absentRelationshipDecodesAsUnloaded() throws {
        let object = ResourceObject(type: "person", id: "1", attributes: ["name": "Solo", "notes": ""])
        let person: Person = try codec.decode(object)
        #expect(person.tags == .unloaded)
        #expect(person.group == .unloaded)
        #expect(person.birthday == nil)
    }

    @Test func missingAttributeReportsKeyNotFound() throws {
        let object = ResourceObject(type: "person", id: "1", attributes: ["notes": ""])
        #expect {
            let _: Person = try codec.decode(object)
        } throws: { error in
            guard case IonError.decoding(let key, let underlying) = error else { return false }
            guard case DecodingError.keyNotFound(let codingKey, _) = underlying else { return false }
            return key == ResourceKey(type: "person", id: "1") && codingKey.stringValue == "name"
        }
    }

    @Test func typeMismatchFails() throws {
        let object = ResourceObject(type: "tag", id: "1", attributes: ["name": "x"])
        #expect(throws: IonError.self) {
            let _: Person = try codec.decode(object)
        }
    }

    @Test func encodesAttributesAndRelationships() throws {
        var person = Person(id: "42", name: "Ann", notes: "n")
        person.birthday = Date(timeIntervalSince1970: 0)
        person.tags = .ids(["7"])
        person.group = .null
        let object = try codec.encode(person)
        #expect(object.type == "person")
        #expect(object.id == "42")
        #expect(object.attributes == ["name": "Ann", "notes": "n", "birthday": "1970-01-01T00:00:00.000Z"])
        #expect(object.relationships["tags"]?.data == .many([ResourceIdentifier(type: "tag", id: "7")]))
        #expect(object.relationships["group"]?.data == .one(nil))
        #expect(object.relationships["friends"] == nil)
        #expect(object.attributes["friends"] == nil)
    }

    @Test func localIDIsOmittedOnEncode() throws {
        let person = Person(id: Person.makeLocalID(), name: "New")
        #expect(person.hasLocalID)
        let object = try codec.encode(person)
        #expect(object.id == nil)
    }

    @Test func roundTripsThroughWire() throws {
        // Millisecond precision on the wire: pick an instant that is exact at that precision.
        var person = Person(id: "42", name: "Ann", notes: "n", updatedAt: Date(timeIntervalSince1970: 1_792_058_400.5))
        person.tags = .ids(["7", "9"])
        person.group = .id("3")
        let back: Person = try codec.decode(try codec.encode(person))
        #expect(back == person)
    }

    @Test func diffSendsOnlyChangedFields() throws {
        var original = Person(id: "42", name: "Ann", notes: "n")
        original.tags = .ids(["7"])
        original.group = .id("3")
        original.birthday = Date(timeIntervalSince1970: 0)
        var changed = original
        changed.name = "Ann B."
        changed.birthday = nil
        changed.tags.ids = ["7", "9"]
        let diff = try codec.diff(from: original, to: changed)
        #expect(diff.id == "42")
        #expect(diff.attributes == ["name": "Ann B.", "birthday": .null])
        #expect(diff.relationships.keys.sorted() == ["tags"])
        #expect(ResourceCodec.isEmptyChange(try codec.diff(from: original, to: original)))
    }

    @Test func diffSendsRelationshipSetOnUnloadedOriginal() throws {
        let original = Person(id: "42", name: "Ann")
        var changed = original
        changed.group.id = "3"
        let diff = try codec.diff(from: original, to: changed)
        #expect(diff.relationships["group"]?.data == .one(ResourceIdentifier(type: "group", id: "3")))
        #expect(diff.attributes.isEmpty)
    }

    @Test func validateRejectsLocalRelationships() throws {
        var person = Person(id: "42", name: "Ann")
        person.group = .id(Group.makeLocalID())
        let object = try codec.encode(person)
        #expect(throws: IonError.self) { try codec.validateForSave(object) }
    }

    @Test func snakeCaseStrategies() throws {
        let codec = ResourceCodec.snakeCase
        var note = Note(id: "1", bodyText: "hello")
        note.author = .id("42")
        let object = try codec.encode(note)
        #expect(object.attributes == ["body_text": "hello"])
        #expect(object.relationships["author"]?.data == .one(ResourceIdentifier(type: "person", id: "42")))
        let wire = ResourceObject(
            type: "note", id: "1",
            attributes: ["body_text": "hi", "created_at": "2026-01-02T03:04:05Z"],
            relationships: ["author": RelationshipObject(data: .one(ResourceIdentifier(type: "person", id: "9")))]
        )
        let decoded: Note = try codec.decode(wire)
        #expect(decoded.bodyText == "hi")
        #expect(decoded.author == .id("9"))
        #expect(decoded.createdAt != nil)
    }

    @Test(arguments: ["updatedAt", "URLValue", "a", "bodyText2", "someURL", "myURLProperty", "_leading", "x_y"])
    func snakeCaseMatchesFoundation(input: String) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(SingleKey(key: input))
        let object = try JSONDecoder().decode([String: Int].self, from: data)
        #expect(object.keys.first == ResourceCodec.snakeCase(input))
    }

    @Test(arguments: ["2026-10-15T10:00:00Z", "2026-10-15T10:00:00.123Z", "2026-10-15T12:00:00+02:00", "2026-10-15T10:00:00.5+00:00"])
    func parsesISO8601Variants(string: String) throws {
        let date = try #require(ISO8601.parse(string))
        #expect(abs(date.timeIntervalSince1970 - 1_792_058_400) < 1)
    }

    @Test func relationshipAccessors() {
        var one: ToOne<Group> = .unloaded
        #expect(one.id == nil)
        #expect(!one.isLoaded)
        one.id = "3"
        #expect(one == .id("3"))
        #expect(one.key == ResourceKey(type: "group", id: "3"))
        one.id = nil
        #expect(one == .null)
        var many: ToMany<Tag> = .unloaded
        #expect(many.ids == [])
        many.ids = ["1", "2"]
        #expect(many == .ids(["1", "2"]))
        #expect(many.keys.map(\.id) == ["1", "2"])
    }
}

private struct SingleKey: Encodable {
    let key: String

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(1, forKey: AnyCodingKey(key))
    }
}
