//  PipelinePrimitives.swift
//  MetalPlayer 重建工程 —— Phase 1 播放管线的三个原语
//
//  这三个东西解决的都是「多线程播放器」里最容易写错的地方：
//
//  1. BoundedQueue   —— 有界阻塞队列。解封装线程靠它给解码线程做背压，
//                       否则 220MB 的 models.dat 还没加载完，内存先被包队列吃光。
//                       必须支持「可打断的等待」：seek / 停止时要能立刻唤醒，
//                       不能傻等在生产者的超时上。
//
//  2. PipelineGate   —— 解码门闸。av_seek_frame / avcodec_flush_buffers / SwrContext
//                       都不是线程安全的，动它们之前必须保证「没有任何解码在途」。
//                       门闸提供 freezeAndWait()：冻结新任务进入，并等待在途任务退出。
//
//  3. PacketBox      —— AVPacket 的 ARC 容器。让包能作为普通 Swift 值在队列里传递，
//                       出队即释放，不必手工 free。

#if USE_FFMPEG

import Foundation
import CFFmpeg

// MARK: - 有界阻塞队列

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
        return items.isEmpty ? nil : items.removeFirst()
    }

    /// 非阻塞出队。
    func tryPop() -> T? {
        condition.lock()
        defer { condition.unlock() }
        return items.isEmpty ? nil : items.removeFirst()
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

// MARK: - RIFE 重排缓冲（乱序完成、按序消费）

/// 多 worker 并行插帧的保序组件（对应原版 RIFEMultiPairReorderBuffer 的核心语义）。
///
/// 调度线程给每个帧对编一个递增 seq；worker 完成顺序不确定，结果以 seq 为键
/// 落进缓冲；出口线程只按 nextSeq 顺序取走。缓冲同时承担在途计数：
/// `waitCapacity` 让调度线程在在途帧对过多时阻塞（背压传导回解码线程），
/// `inflight` 供 protect interval 判断是否跳过本对插帧。
final class RifeReorderBuffer {
    private let cond = NSCondition()
    private var items: [Int: (gen: Int, frames: [DecodedVideoFrame])] = [:]
    private var nextSeq = 0
    private var submitted = -1
    private var closed = false

    /// 在途（已提交未消费）的 seq 数。
    var inflight: Int {
        cond.lock(); defer { cond.unlock() }
        return submitted - nextSeq + 1
    }

    /// 重排缓冲里未消费的结果数（遥测用：持续增长 = 出口线程卡死）。
    var pendingCount: Int {
        cond.lock(); defer { cond.unlock() }
        return items.count
    }

    /// 调度线程：登记 seq（先于派发，容量窗口把调度中的作业也算在途）。
    func submit(seq: Int) {
        cond.lock()
        submitted = max(submitted, seq)
        cond.broadcast()
        cond.unlock()
    }

    /// worker：结果落位（空 frames = 换代丢弃，占位保序）。
    /// 已被看门狗跳过（seq < nextSeq）的迟到结果直接丢弃，防 items 字典漏收。
    func push(seq: Int, gen: Int, frames: [DecodedVideoFrame]) {
        cond.lock()
        guard seq >= nextSeq else {
            cond.unlock()
            return
        }
        items[seq] = (gen, frames)
        cond.broadcast()
        cond.unlock()
    }

    /// 调度线程：在途达到 cap 时阻塞。返回 false = 已关闭（应退出）。
    func waitCapacity(_ cap: Int) -> Bool {
        cond.lock()
        defer { cond.unlock() }
        while submitted - nextSeq + 1 >= cap && !closed {
            cond.wait()
        }
        return !closed
    }

    /// 出口线程：阻塞取下一序结果。nil = 已关闭。
    ///
    /// 看门狗：正常情况下每个已提交的 seq 必有结果落位（worker 即使失败也
    /// 返回占位结果）。等超过 3 秒说明流水线内部出了缺陷（作业丢失/线程异常），
    /// 与其永久卡死播放，不如跳过该 seq 自愈并记日志。
    func next() -> (gen: Int, frames: [DecodedVideoFrame])? {
        cond.lock()
        defer { cond.unlock() }
        var waited: TimeInterval = 0
        while items[nextSeq] == nil && !closed {
            if waited > 3.0 {
                NSLog("[RIFE60] 看门狗：seq %d 超时未完成，强制跳过（累计 %.1fs）",
                      nextSeq, waited)
                nextSeq += 1
                waited = 0
                cond.broadcast()
                continue
            }
            let t0 = Date()
            cond.wait(until: t0.addingTimeInterval(0.5))
            waited += Date().timeIntervalSince(t0)
        }
        guard let r = items.removeValue(forKey: nextSeq) else { return nil }
        nextSeq += 1
        cond.broadcast()   // 容量窗口前移，唤醒等容量的调度线程
        return r
    }

    /// seek/换流：丢弃全部未消费结果，nextSeq 直接跳过已提交区间
    /// （被丢弃的作业不会再有结果落位，等它们只会死锁）。
    func discardPending() {
        cond.lock()
        items.removeAll()
        nextSeq = submitted + 1
        cond.broadcast()
        cond.unlock()
    }

    func close() {
        cond.lock()
        closed = true
        cond.broadcast()
        cond.unlock()
    }

    func reopen() {
        cond.lock()
        closed = false
        items.removeAll()
        // 线程在 shutdown 时全部退出重启，调度线程的 seq 从 0 起算，
        // 这里必须同步归零（中途 seek 用 discardPending 保持连续性，不能混用）。
        nextSeq = 0
        submitted = -1
        cond.broadcast()
        cond.unlock()
    }
}

// MARK: - 内存足迹遥测

enum MemoryFootprint {
    /// 三个口径，别混着看 —— 排查内存时必须先说清看的是哪个：
    ///
    ///   · **phys_footprint**：内核记的「物理足迹」，Activity Monitor「内存」列
    ///     大体就是这个数。它**不计 IOSurface 后备页**，所以显存侧的膨胀
    ///     在这里看不出来。
    ///   · **RSS（resident_size）**：实际驻留的物理页数，含被映射进来的
    ///     IOSurface / 内存映射文件页。补帧链路大量使用 IOSurface，
    ///     RSS 通常明显高于 footprint。
    ///   · **compressed**：被压缩器压住的量。Activity Monitor 的「已压缩内存」，
    ///     它涨到几 GB 时，即使 footprint 平稳，用户感受到的也是「内存爆了」。
    ///
    /// 排查铁律：三个数一起采样，只看一个会得出相反结论（实测同一场景里
    /// footprint 平稳而 RSS 持续爬升是完全可能的）。
    private static func vmInfo() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info : nil
    }

    static func currentMB() -> Double {
        guard let info = vmInfo() else { return -1 }
        return Double(info.phys_footprint) / 1048576.0
    }

    /// 常驻物理内存（RSS），MB。Activity Monitor 观感最直接的一个数。
    static func residentMB() -> Double {
        guard let info = vmInfo() else { return -1 }
        return Double(info.resident_size) / 1048576.0
    }

    /// 被压缩的量。涨到 GB 级说明系统在拿 CPU 换内存。
    ///
    /// 注意单位是**字节**：`task_vm_info.compressed` 是 `mach_vm_size_t`，
    /// 与同结构里的 `page_size` 无关（第一版按页数换算，直接报出 1.2TB）。
    static func compressedMB() -> Double {
        guard let info = vmInfo() else { return -1 }
        return Double(info.compressed) / 1048576.0
    }
}

// MARK: - 解码门闸

/// 「互斥 + 可冻结」的门闸，用来串行化对**同一个**编解码上下文的访问。
///
/// 为什么需要它（血泪教训）：
///   FFmpeg 的帧级线程（`thread_count > 0`）有一个内部 async 锁，
///   `ff_thread_decode_frame()` 进入时会**无条件释放**它、返回前再拿回。
///   这个不变式只在「同一时刻只有一个线程在跟这个 AVCodecContext 打交道」时成立。
///   一旦两个线程同时进去，第二个就会看到 `fctx->async_lock == 0`，
///   直接 `av_assert0` 中止进程：
///       Assertion fctx->async_lock failed at libavcodec/pthread_frame.c:178
///
///   而 `av_seek_frame` / `avcodec_flush_buffers` / `SwrContext` 同样不是线程安全的。
///
/// 所以门闸要同时提供两件事：
///   1. **互斥**：同一时刻只有一个持有者（这是第一版漏掉的 —— 只做了一个
///      冻结判断，结果 video 线程和 demux 线程可以同时进入同一个解码器）。
///   2. **冻结**：seek 时阻止新持有者进入，并等在途持有者退出，
///      之后调用者可以独占所有 context。
///
/// 粒度：**每个编解码上下文一个门闸**（videoGate / audioGate）。
/// 视频和音频是两套独立 context，用同一个门闸会把它们的解码串行化，
/// 白白丢掉并行度。
final class PipelineGate {

    private let condition = NSCondition()
    private var active = 0
    private var frozen = false

    /// 取门。已被占用或处于冻结状态时阻塞。
    func enter() {
        condition.lock()
        while frozen || active > 0 { condition.wait() }
        active += 1
        condition.unlock()
    }

    func leave() {
        condition.lock()
        active -= 1
        if active == 0 { condition.broadcast() }
        condition.unlock()
    }

    /// 冻结并等待在途操作结束。返回后调用者可以独占对应 context。
    ///
    /// 约束：调用者不能正持有同一把门 —— 否则自己等自己。目前只有解封装线程调用，
    /// 且调用时一定在门之外。
    ///
    /// `timeout` 是**兜底**，不是正常路径。门内的正常操作就是「解一帧」，
    /// 毫秒级就该出来；等满这个数说明持门者卡在别处了 —— 最典型的是
    /// 阻塞在一个满队列的 push 上（帧队列满 + 渲染停摆时就是死结）。
    /// 与其让 freezeAndWait 无限等下去把整个 UI 拖死（用户侧是「进度条拖不动」），
    /// 不如超时放行并留下线索。调用方在冻结前会先清帧队列，正常走不到超时。
    func freezeAndWait(timeout: TimeInterval = 5.0) {
        condition.lock()
        frozen = true
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        var activeAtTimeout = 0
        while active > 0 {
            if !condition.wait(until: deadline) {
                timedOut = true
                activeAtTimeout = active
                break
            }
        }
        condition.unlock()
        if timedOut {
            let msg = "[PipelineGate] 警告：冻结等待超时 \(timeout)s，强制放行"
                + "（在途 \(activeAtTimeout)）—— 持门者可能卡在满队列的 push 上\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }
    }

    func unfreeze() {
        condition.lock()
        frozen = false
        condition.broadcast()
        condition.unlock()
    }
}

// MARK: - AVPacket 的 ARC 容器

final class PacketBox {

    let packet: UnsafeMutablePointer<AVPacket>

    init?() {
        guard let p = av_packet_alloc() else { return nil }
        packet = p
    }

    /// 从 source 复制一份（source 归 MediaFileSource 复用，不能直接持有）。
    init?(copying source: UnsafeMutablePointer<AVPacket>) {
        guard let p = av_packet_alloc() else { return nil }
        packet = p
        if av_packet_ref(p, source) < 0 {
            var tmp: UnsafeMutablePointer<AVPacket>? = p
            av_packet_free(&tmp)
            return nil
        }
    }

    deinit {
        var p: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&p)
    }
}

/// 包队列里的元素。
///
/// 为什么要一个「流结束」标记，而不是让解封装线程直接去冲刷解码器：
///
///   解封装线程的读速远快于解码（本地文件几百个包不到 0.5 秒就读完了），
///   它触到 EOF 时，两个解码线程的队列里往往还堆着几百个包。
///   这时候如果跨线程调 `avcodec_flush_buffers`，会把解码器里的
///   **参考帧/GOP 状态全部丢掉** —— 后面的非关键帧就再也解不出来了。
///   症状非常隐蔽：画面停在开头几帧，而日志里解码、时钟、渲染全都"正常"。
///
///   正确做法是让冲刷发生在**拥有这个解码器的线程**上，且必须等它把
///   队列里的包真正消费完。EOS 标记沿队列 FIFO 传播，天然保证了这一点。
enum PacketItem {
    case packet(PacketBox)
    /// 该流已到文件尾；解码线程收到后自行冲刷，把尾巴帧取出来。
    case endOfStream
}

#endif
