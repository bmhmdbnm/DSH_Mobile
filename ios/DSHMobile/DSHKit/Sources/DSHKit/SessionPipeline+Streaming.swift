import Foundation

/// SessionPipeline 的流式半边（文件按职责拆分，沿用 `MessageStore+Records` 先例）：
/// 主文件管区间/水合/拉取，这里管 spec「剩余卡顿源①」的流式按帧合并。
///
/// 纪律：agent 增量不允许逐 token 提交——先进 `streamBuffers`，经注入的
/// `frameTick` 节拍（测试立即返回，产品接 CADisplayLink/16ms）合并，
/// 一个 tick 内的多次增量只出一次状态变更（一次 diff）。
extension SessionPipeline {

    /// 一次流式尝试的合并缓冲（attemptId → 目标 seq + 累计文本）。
    struct StreamBuffer {
        var seq: Int
        var text: String
        var dirty: Bool
    }

    /// 流式增量：先进缓冲，按帧节拍合并（tick 内多次只出一次 diff）。
    public func apply(stream frame: AssistantStreamFrame) {
        switch frame {
        case .start(let attemptId, _, _, _, let startedAfterSeq):
            streamBuffers[attemptId] = StreamBuffer(seq: startedAfterSeq + 1, text: "", dirty: false)
        case .chunk(let attemptId, _, _, _, let chunk):
            guard var buffer = streamBuffers[attemptId], let text = chunk.text else { return }
            buffer.text += text
            buffer.dirty = true
            streamBuffers[attemptId] = buffer
            scheduleStreamFlush()
        case .end(let attemptId, _, _, _):
            // 提交的 assistant/message 事件会随后到达并覆盖；缓冲直接丢。
            streamBuffers.removeValue(forKey: attemptId)
        case .unknown:
            break
        }
    }

    /// 同一时刻只挂一个节拍任务：tick 内后续增量只写缓冲、不再起新任务。
    private func scheduleStreamFlush() {
        guard !streamFlushScheduled else { return }
        streamFlushScheduled = true
        Task { [frameTick] in
            await frameTick()
            self.flushStreams()
        }
    }

    /// 一帧一次：把 tick 内累计的所有流式文本合并成一次状态变更。
    private func flushStreams() {
        streamFlushScheduled = false
        var diff = Diff()
        for (attemptId, var buffer) in streamBuffers where buffer.dirty {
            buffer.dirty = false
            streamBuffers[attemptId] = buffer
            let record = SessionRecord(event: SessionEvent(
                type: "assistant/message", seq: buffer.seq, time: nil,
                data: .object(["text": .string(buffer.text)]), surfaceOp: nil))
            if hotWindow[buffer.seq] == nil { diff.inserted.append(record) } else { diff.updated.append(record) }
            mergeIntoHotWindow(record)
            enqueueWrite(.upsertRecords(scope: scope, sessionId: sessionId, records: [record]),
                         key: buffer.seq)
        }
        guard !diff.isEmpty else { return }
        diff.removed = evictIfNeeded()
        diff.gaps = currentGaps()
        emit(diff)
    }
}
