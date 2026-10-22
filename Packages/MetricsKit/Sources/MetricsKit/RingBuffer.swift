/// Fixed-capacity FIFO that overwrites its oldest element when full.
/// 60 minutes of history at a 2 s interval is `RingBuffer(capacity: 1_800)`.
public struct RingBuffer<Element: Sendable>: Sendable {
    public let capacity: Int
    private var storage: [Element] = []
    /// Index of the oldest element once the buffer is full.
    private var head = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be positive")
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    public mutating func append<S: Sequence>(contentsOf elements: S) where S.Element == Element {
        for element in elements { append(element) }
    }

    /// Oldest first.
    public var elements: [Element] {
        guard head > 0 else { return storage }
        return Array(storage[head...] + storage[..<head])
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public var isFull: Bool { storage.count == capacity }

    /// Newest element.
    public var last: Element? {
        guard !storage.isEmpty else { return nil }
        return storage.count < capacity ? storage.last : storage[(head + capacity - 1) % capacity]
    }

    /// Oldest element.
    public var first: Element? {
        guard !storage.isEmpty else { return nil }
        return storage.count < capacity ? storage.first : storage[head]
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }
}
