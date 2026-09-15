//
//  Locked.swift
//  LoopKit
//
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import os.lock


internal class Locked<T> {
    // A heap pointer rather than a stored struct: `&lock` on a property holds
    // an inout access for as long as the thread blocks in os_unfair_lock_lock,
    // and a second thread reaching `&lock` then trips Swift's exclusivity
    // check ("Simultaneous accesses"). Apple documents the same pitfall.
    private let lock: os_unfair_lock_t
    private var _value: T

    init(_ value: T) {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        _value = value
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    var value: T {
        get {
            os_unfair_lock_lock(lock)
            defer { os_unfair_lock_unlock(lock) }
            return _value
        }
        set {
            os_unfair_lock_lock(lock)
            defer { os_unfair_lock_unlock(lock) }
            _value = newValue
        }
    }

    func mutate(_ changes: (_ value: inout T) -> Void) -> T {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        changes(&_value)
        return _value
    }
}
