import Combine
import Foundation

/// Like @Published, but announces a change only when the value differs. SwiftUI scenes on macOS 26
/// write some bindings back on every update (MenuBarExtra's isInserted, searchable's text); with
/// @Published each write-back re-evaluates the app body, which writes again, which hangs the app.
@propertyWrapper
struct Changed<Value: Equatable> {
    private var value: Value
    private let key: String?

    init(wrappedValue: Value, _ key: String? = nil) {
        self.key = key
        if let key, let stored = UserDefaults.standard.object(forKey: key) as? Value { value = stored } else { value = wrappedValue }
    }

    @available(*, unavailable, message: "@Changed works only inside an ObservableObject class")
    var wrappedValue: Value { get { fatalError() } set { fatalError() } }

    static subscript<T: ObservableObject>(
        _enclosingInstance instance: T,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<T, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<T, Self>
    ) -> Value where T.ObjectWillChangePublisher == ObservableObjectPublisher {
        get { instance[keyPath: storageKeyPath].value }
        set {
            guard instance[keyPath: storageKeyPath].value != newValue else { return }
            instance.objectWillChange.send()
            instance[keyPath: storageKeyPath].value = newValue
            if let key = instance[keyPath: storageKeyPath].key { UserDefaults.standard.set(newValue, forKey: key) }
        }
    }
}
