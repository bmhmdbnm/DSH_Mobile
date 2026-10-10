import Foundation

/// 单会话内存流水线（spec 009 架构决定 §2）：热窗口、区间集、预取瀑布、
/// in-flight 页表、落库队列、流式按帧合并。T008 实现。
