import Foundation

/// 排版预计算缓存（spec 009 §4 / tasks T007）。
///
/// 两类严格分开：
/// - **A 类（环境无关）**：Markdown AST、代码块高亮、摘要——算一次终身有效，
///   内存字典持有（落库由 MessageStore 侧负责，本类只管内存）。
/// - **B 类（环境相关）**：行高、布局结果——key 必须带 `TypesetEnvironment`
///   （宽度档/字体档/深浅色），环境变了自然失配不混用；只进 `NSCache`，
///   按字节 LRU（`totalCostLimit`），内存压力下系统自动回收。
///
/// 值是 `any Sendable` 存在盒子：排版结果的具体类型（AST、NSAttributedString
/// 包装等）由 App 侧定义，本层不依赖 UI 类型（宪法 VII.1 依赖倒置——解析器
/// 由上层注入，缓存不认识它产物的形状）。
public final class TypesetCache: @unchecked Sendable {

    /// B 类缓存 key 的环境维度（spec：宽度/字体档位/深浅色）。
    public struct Environment: Hashable, Sendable {
        public let widthBucket: Int
        public let textSizeRank: Int
        public let dark: Bool

        public init(widthBucket: Int, textSizeRank: Int, dark: Bool) {
            self.widthBucket = widthBucket
            self.textSizeRank = textSizeRank
            self.dark = dark
        }
    }

    /// NSCache 只收对象；值盒保证 `any Sendable` 不泄到 API 面。
    /// `@unchecked`：NSObject 子类无法声明 Sendable，但 Box 不可变且只经
    /// NSCache 进出，共享是安全的。
    private final class Box: NSObject, @unchecked Sendable {
        let value: any Sendable
        init(_ value: any Sendable) { self.value = value }
    }

    private let bStore = NSCache<NSString, Box>()
    private var aStore: [String: any Sendable] = [:]
    private let aLock = NSLock()
    /// A 类条数软上限（防无界增长；A 类单体小，上限按条数足够）。
    private let aLimit: Int

    public init(bBytesLimit: Int, aLimit: Int = 4000) {
        bStore.totalCostLimit = bBytesLimit
        self.aLimit = aLimit
    }

    // MARK: - A 类（环境无关）

    public func aValue(for key: String) -> (any Sendable)? {
        aLock.lock()
        defer { aLock.unlock() }
        return aStore[key]
    }

    public func setA(_ value: any Sendable, for key: String) {
        aLock.lock()
        defer { aLock.unlock() }
        // 超上限时整表打折（简单策略；A 类重建成本低，不值得维护 LRU 链表）。
        if aStore.count >= aLimit {
            aStore = aStore.filter { _ in Bool.random() }
        }
        aStore[key] = value
    }

    // MARK: - B 类（环境相关，NSCache 字节 LRU）

    public func bValue(for key: String, in environment: Environment) -> (any Sendable)? {
        bStore.object(forKey: Self.bKey(key, environment))
    }

    public func setB(_ value: any Sendable, for key: String,
                     in environment: Environment, cost: Int) {
        bStore.setObject(Box(value), forKey: Self.bKey(key, environment), cost: cost)
    }

    /// 环境进 key：宽度/字体/深浅色变化自然失配，永不混用（spec §4）。
    private static func bKey(_ key: String, _ environment: Environment) -> NSString {
        "\(key)|w\(environment.widthBucket)|t\(environment.textSizeRank)|d\(environment.dark ? 1 : 0)" as NSString
    }
}
