import Foundation

/// SessionPipeline 的流式半边（文件按职责拆分，沿用 `MessageStore+Records` 先例）：
/// 主文件管区间/水合/拉取，这里管 spec「剩余卡顿源①」的流式按帧合并。
///
/// 纪律：agent 增量不允许逐 token 提交——先进 `streamBuffers`，经注入的
/// `frameTick` 节拍（测试立即返回，产品接 CADisplayLink/16ms）合并，
/// 一个 tick 内的多次增量只出一次状态变更（一次 diff）。
///
/// 记录形状（spec 009 tasks T020）：缓冲吐出的 provisional 记录与线上
/// `assistant/message` 提交记录同形（`message.content` 块），外加
/// `stream: true` 标记——折叠层据此把行标成 `isStreaming`（渲染降级为
/// 纯文本、代码块不高亮），桥据此走单行增量更新而不是整树重折；
/// 消息结束后的提交事件（同 seq）原地覆盖，标记消失，触发一次完整解析。
extension SessionPipeline {

    /// 一次流式尝试的合并缓冲（attemptId → 目标 seq + 累计文本/思考）。
    struct StreamBuffer {
        var seq: Int
        var turn: Int
        var step: Int
        var text = ""
        var reasoning = ""
        var dirty = false
    }

    /// 流式增量：先进缓冲，按帧节拍合并（tick 内多次只出一次 diff）。
    public func apply(stream frame: AssistantStreamFrame) {
        switch frame {
        case .start(let attemptId, _, let turn, let step, let startedAfterSeq):
            streamBuffers[attemptId] = StreamBuffer(
                seq: startedAfterSeq + 1, turn: turn, step: step)
        case .chunk(let attemptId, _, _, _, let chunk):
            guard var buffer = streamBuffers[attemptId] else { return }
            // 只收文本/思考增量：工具参数增量由随后的 `tool/call` 事件承载，
            // 拼进 provisional 文本会把生 JSON 漏进气泡。
            switch chunk {
            case .textDelta(let delta): buffer.text += delta
            case .reasoningDelta(let delta): buffer.reasoning += delta
            case .toolCallDelta, .other: return
            }
            buffer.dirty = true
            streamBuffers[attemptId] = buffer
            scheduleStreamFlush()
        case .end(let attemptId, _, _, let committedSeq):
            guard let buffer = streamBuffers.removeValue(forKey: attemptId) else { return }
            // 提交事件会随后以同 seq 覆盖 provisional 行；只有「没提交上」
            // （取消/出错）或提交落在别的 seq 时，才要把 provisional 行撤掉。
            guard committedSeq != buffer.seq, hotWindow[buffer.seq] != nil else { return }
            hotWindow.removeValue(forKey: buffer.seq)
            emit(Diff(removed: [buffer.seq], gaps: currentGaps()))
        case .unknown:
            break
        }
    }

    /// 提交事件落窗时作废旧缓冲（主文件 `apply(events:)` 调用）：
    /// 提交可能抢在已排期的 flush 之前到达，不丢缓冲的话，随后的 flush
    /// 会用旧的 provisional 文本把刚提交的正式内容盖回去。
    func discardStreamBuffers(committedAt seqs: Set<Int>) {
        guard !seqs.isEmpty else { return }
        streamBuffers = streamBuffers.filter { !seqs.contains($0.value.seq) }
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
            let record = SessionRecord(event: Self.provisionalEvent(buffer))
            if hotWindow[buffer.seq] == nil { diff.inserted.append(record) } else { diff.updated.append(record) }
            mergeIntoHotWindow(record)
            // provisional 记录不落库：提交事件会以同 seq 写正式内容，
            // 崩在半路时重连后快照也会带来正式记录（spec §3 兜底）。
        }
        guard !diff.isEmpty else { return }
        _ = evictIfNeeded()
        diff.gaps = currentGaps()
        emit(diff)
    }

    /// provisional 记录：与提交记录同形（`message.content`），`stream: true`
    /// 是「还在流式」的唯一标记（折叠→isStreaming，桥→单行增量路径）。
    private static func provisionalEvent(_ buffer: StreamBuffer) -> SessionEvent {
        var content: [JSONValue] = []
        if !buffer.reasoning.isEmpty {
            content.append(.object(["type": .string("reasoning"), "text": .string(buffer.reasoning)]))
        }
        content.append(.object(["type": .string("text"), "text": .string(buffer.text)]))
        return SessionEvent(
            type: "assistant/message", seq: buffer.seq, time: nil,
            data: .object([
                "turn": .int(buffer.turn),
                "step": .int(buffer.step),
                "stream": .bool(true),
                "message": .object(["content": .array(content)]),
            ]),
            surfaceOp: nil)
    }
}
