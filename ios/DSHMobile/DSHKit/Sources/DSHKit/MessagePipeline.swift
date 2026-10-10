import Foundation

/// 内存层枢纽（spec 009 架构决定 §1）：唯一数据分发点。
/// 下行：网络 → 本 actor → 两路（控件快照 diff / 批量落库）。
/// 上行：控件动作 → 本 actor → 落 pending → 网络。
/// T009 实现快照流契约（contracts/memory-pipeline.md）。
