import Foundation

/// GRDB 版磁盘层（spec 009 research D1）：record/session_state/user_inputs(+FTS5)，
/// WAL、批量写队列、区间读。取代 007 的手写 TranscriptStore（T027 删除旧层）。
/// T004 实现 schema，T005 实现批量写队列。
