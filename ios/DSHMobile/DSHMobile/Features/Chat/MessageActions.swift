import DSHKit
import SwiftUI
import UIKit

/// The long-press menu a transcript row gets when it holds copyable text.
///
/// Rows without text (dividers, notices, events this build does not render)
/// deliberately answer with no menu at all: a menu that opens onto nothing is a
/// worse answer than no menu.
///
/// **规则（2026-10-12 定为纪律）**：凡是能拿到这份菜单的行，就**不要再**声明就地选字
/// （`.textSelection(.enabled)`）。理由是被实测过的现状——转写行住在 `List` 里，长按先被
/// cell 接走（同一处注释也在 `ChatView` 里），声明了也到不了手指；它还会与单元格高亮
/// 叠加：轻点回答正文后整块矩形留下灰色"选中"底（owner 2026-10-12 截图）。选择入口就是
/// 这份菜单里的「选择文本」，那一页由 `UITextView` 自己接管手势，是真正可用的那个。
///
/// 例外：`selectableMessage` 为 nil 的行（思考过程、提示、分隔、缺口）**没有**这份菜单，
/// 它们的就地选字不会被 cell 接走，因此仍保留 `.textSelection(.enabled)`。
struct MessageActions: ViewModifier {
    let item: TimelineItem
    /// Opens the message on its own page, where its text can be selected.
    let onOpen: (MessageSelection) -> Void

    func body(content: Content) -> some View {
        if let payload = item.selectableMessage {
            content.contextMenu {
                Button {
                    onOpen(
                        MessageSelection(
                            id: item.id,
                            title: payload.title,
                            text: payload.text,
                            isMonospaced: payload.isMonospaced
                        )
                    )
                } label: {
                    Label("选择文本", systemImage: "text.cursor")
                }

                Button {
                    UIPasteboard.general.string = payload.text
                } label: {
                    Label("拷贝整条消息", systemImage: "doc.on.doc")
                }
            }
        } else {
            content
        }
    }
}
