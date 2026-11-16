import Foundation

final class BoundedQueue<T> {

    private let condition = NSCondition()
    private var items: [T] = []
    private let capacity: Int
    private var closed = false

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int {
        condition.lock(); defer { condition.unlock() }
        return items.count
    }

    var isEmpty: Bool { count == 0 }

    /// 入队。队列满时最多等 `timeout` 秒；超时返回 false（元素没有被消耗）。
    @discardableResult
    func push(_ item: T, timeout: TimeInterval = 0.1) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while items.count >= capacity && !closed {
            if !condition.wait(until: deadline) { return false }
        }
        if closed { return false }
        items.append(item)
        condition.signal()
        return true
    }

    /// 出队。空队列会阻塞等待。队列被 close 且排空时返回 nil。
    func pop() -> T? {
        condition.lock()
        defer { condition.unlock() }
        while items.isEmpty && !closed { condition.wait() }
        guard !items.isEmpty else { return nil }
        let item = items.removeFirst()
        condition.broadcast()
        return item
    }

    /// 非阻塞出队。
    func tryPop() -> T? {
        condition.lock()
        defer { condition.unlock() }
        guard !items.isEmpty else { return nil }
        let item = items.removeFirst()
        condition.broadcast()
        return item
    }

    /// 非阻塞批量入队；在同一把锁内淘汰旧元素，容量变化时也立即收紧。
    /// 返回丢弃数量（包括批次自身超过预算的部分）。关闭后不再接收。
    @discardableResult
    func pushKeepingNewest(_ incoming: [T], limit: Int) -> Int {
        condition.lock()
        defer { condition.unlock() }
        guard !closed else { return incoming.count }
        let budget = max(1, min(capacity, limit))
        let dropped = max(0, items.count + incoming.count - budget)
        let oldDropped = min(items.count, dropped)
        items.removeFirst(oldDropped)
        items.append(contentsOf: incoming.dropFirst(dropped - oldDropped))
        condition.broadcast()
        return dropped
    }

    func peekLast() -> T? {
        condition.lock(); defer { condition.unlock() }
        return items.last
    }

    /// 清空。用于 seek —— 必须广播唤醒等待者，否则生产者/消费者会卡在旧状态上。
    func flush() {
        condition.lock()
        items.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    /// 重新启用（配合 close 用于「停止 → 换文件」的复用）。
    func reopen() {
        condition.lock()
        closed = false
        items.removeAll()
        condition.broadcast()
        condition.unlock()
    }
}

