import Foundation
import IonKit

struct Person: Resource {
    static let resourceType = "person"
    static let collectionPath = "people"

    var id: String
    var name: String
    var birthday: Date?
    var notes: String = ""
    var updatedAt: Date?
    var tags: ToMany<Tag> = .unloaded
    var group: ToOne<Group> = .unloaded
    var friends: ToMany<Person> = .unloaded

    var initials: String {
        name.split(separator: " ").compactMap(\.first).map(String.init).joined()
    }
}

struct Tag: Resource {
    static let resourceType = "tag"

    var id: String
    var name: String
}

struct Group: Resource {
    static let resourceType = "group"

    var id: String
    var name: String
    var members: ToMany<Person> = .unloaded
}

/// A snake_case server's resource.
struct Note: Resource {
    static let resourceType = "note"

    var id: String
    var bodyText: String
    var createdAt: Date?
    var author: ToOne<Person> = .unloaded
}

enum TestFixtures {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: name, withExtension: "json")
        else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
        }
        return try Data(contentsOf: url)
    }

    static func document(_ name: String) throws -> JSONAPIDocument {
        try JSONAPIDocument.decode(try data(name))
    }
}
