import Foundation

/// 排版预计算缓存（spec 009 §4）：A 类（环境无关，可落库）与 B 类（环境相关，
/// NSCache 字节 LRU，key 含 messageId/width/textSize/dark）。
/// T007 实现。
