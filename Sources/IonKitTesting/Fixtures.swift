import Foundation
import IonKit

/// Helpers for building wire objects and documents from resource values in tests.
///
/// Usage: `Fixtures.object(tag)` to put a related resource into a mock response's `included`.
public enum Fixtures {
    /// The resource object for a value, through the codec.
    public static func object<T: Resource>(_ value: T, codec: ResourceCodec = .default) -> ResourceObject {
        try! codec.encode(value)
    }

    /// Resource objects for values of one type.
    public static func objects<T: Resource>(_ values: [T], codec: ResourceCodec = .default) -> [ResourceObject] {
        values.map { object($0, codec: codec) }
    }

    /// A single-resource document.
    public static func document<T: Resource>(_ value: T, included: [ResourceObject] = [], codec: ResourceCodec = .default) -> JSONAPIDocument {
        JSONAPIDocument(one: object(value, codec: codec), included: included)
    }

    /// A collection document.
    public static func document<T: Resource>(_ values: [T], included: [ResourceObject] = [], links: Links? = nil, codec: ResourceCodec = .default) -> JSONAPIDocument {
        JSONAPIDocument(many: objects(values, codec: codec), included: included, links: links)
    }

    /// Reads a fixture file from a bundle's `Resources` folder.
    public static func data(named name: String, in bundle: Bundle) throws -> Data {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        let (base, ext) = parts.count == 2 ? (parts[0], parts[1]) : (name, "json")
        guard let url = bundle.url(forResource: base, withExtension: ext)
            ?? bundle.url(forResource: base, withExtension: ext, subdirectory: "Resources")
        else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
        }
        return try Data(contentsOf: url)
    }
}
