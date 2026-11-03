import Combine
import Foundation
import Observation

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

/// What `@Distinct` needs from its class: a way to the registrar calls `@Observable` writes for it. Each is one line
/// (AppState.swift): `access(keyPath:)` and `withMutation(keyPath:_:)`.
@MainActor
protocol DistinctTracking: AnyObject {
    func distinctAccess<Member>(_ keyPath: KeyPath<Self, Member>)
    func distinctMutation<Member>(_ keyPath: KeyPath<Self, Member>, _ mutation: () -> Void)
}

/// @Changed for an @Observable class (AppState): reading the value is tracked, and only a different value is
/// announced. With @Observable alone, setting an equal value still announces a change, which brings back the macOS 26
/// write-back loop above. Mark the property @ObservationIgnored so the macro leaves it to this wrapper:
/// `@ObservationIgnored @Distinct var search = ""`, or `@ObservationIgnored @Distinct("key") var sounds = true` to
/// keep it in UserDefaults.
@propertyWrapper
struct Distinct<Value: Equatable> {
    private var value: Value
    private let key: String?

    init(wrappedValue: Value, _ key: String? = nil) {
        self.key = key
        if let key, let stored = UserDefaults.standard.object(forKey: key) as? Value { value = stored } else { value = wrappedValue }
    }

    @available(*, unavailable, message: "@Distinct works only inside an @Observable class")
    var wrappedValue: Value { get { fatalError() } set { fatalError() } }

    @MainActor static subscript<T: DistinctTracking>(
        _enclosingInstance instance: T,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<T, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<T, Self>
    ) -> Value {
        get {
            instance.distinctAccess(wrappedKeyPath)
            return instance[keyPath: storageKeyPath].value
        }
        set {
            guard instance[keyPath: storageKeyPath].value != newValue else { return }
            instance.distinctMutation(wrappedKeyPath) {
                instance[keyPath: storageKeyPath].value = newValue
            }
            if let key = instance[keyPath: storageKeyPath].key { UserDefaults.standard.set(newValue, forKey: key) }
        }
    }
}
