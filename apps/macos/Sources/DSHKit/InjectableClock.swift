import Foundation

/// 可注入的时钟缝。
///
/// WHY THIS FILE EXISTS
/// --------------------
/// 宿主里所有「等一会儿」的地方（握手窗口、请求超时、心跳节律、重连退避）都
/// 走一个可注入的闭包，测试才能把 15s 换成「立刻返回」而不是真的睡。这本身
/// 是老做法，但**这些闭包的默认值必须是命名的 `static let`，不能写成默认参数
/// 里的闭包字面量**：
///
/// ```swift
/// // 会在运行期 abort：
/// init(sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })
/// // 正确：
/// init(sleeper: SleepFunction? = nil) { self.sleeper = sleeper ?? SystemSleep.duration }
/// ```
///
/// 原因（实测，Swift 6.x / macOS 26）：默认参数表达式是在**调用方**的上下文里
/// 求值的。当调用方本身处于一个 async 任务里（例如 `swift-testing` 的测试体、
/// 或 app 启动时的 `Task {}`），这个 async 闭包的 reabstraction thunk 上下文
/// 会落在**调用方任务的栈分配器**上；之后闭包被存进对象、在**另一个任务**
/// （这里是握手看门狗 / 超时等待）里 `await` 并释放，Swift 并发运行时就会以
/// `freed pointer was not the last allocation` 直接 `abort()`（SIGABRT）。
///
/// 这个坑很毒，因为它只在「用默认参数」的路径上炸：单测一贯注入假时钟，所以
/// 全绿；而生产代码全部走默认参数，于是握手一成功、看门狗一被取消就整个进程
/// 挂掉。W1 dogfood 前的最后一公里就是被它咬的（`docs/known-gaps.md` G-6）。
public typealias SleepFunction = @Sendable (Duration) async throws -> Void

/// 秒为单位的版本（数据通道的重连退避用 `TimeInterval` 说话）。
public typealias SecondsSleepFunction = @Sendable (TimeInterval) async throws -> Void

/// 生产时钟：进程内唯一实例，创建在同步的静态初始化上下文里。
public enum SystemSleep {
    public static let duration: SleepFunction = { try await Task.sleep(for: $0) }
    public static let seconds: SecondsSleepFunction = { try await Task.sleep(for: .seconds($0)) }
}

/// 生产「现在」。同上：命名常量，不写在默认参数里。
public enum SystemClock {
    public static let now: @Sendable () -> Date = { Date() }
}
