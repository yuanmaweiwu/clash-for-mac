import SwiftUI

/// 面板内单行输入框（§2.7 `size/field`）：30pt 高、左右 8pt 内边距、`radius/control` 圆角。
///
/// 四态：
/// - 静止：`surface/track` 底 + 1pt `stroke/hairline`
/// - hover：描边换 `stroke/emphasis`
/// - 聚焦：强调色 1.5pt 描边，系统焦点环保留关闭（`.focusEffectDisabled()`）
/// - 禁用：整体 60% 不透明，不接受输入（由外层 `.disabled` 传入）
///
/// 占位符 `text/tertiary`、正文 `text/primary`；数字框用 `Typography.number` 等宽右对齐。
/// 校验失败时红框 + 红字，优先级高于 hover / 聚焦（端口这类输入要一直看得见错）。
@MainActor
struct PanelTextField: View {

    /// 内容排版：端口 / 数值用等宽右对齐，其余左对齐
    enum Kind {
        case text
        case number
    }

    let placeholder: String
    @Binding var text: String
    /// VoiceOver 读的名字：不随占位符变化（占位符是提示，不是标签）
    let label: String
    var hint: String?
    var kind: Kind = .text
    /// 校验失败：红框 + 红字
    var isInvalid = false
    /// 页面打开即落焦点（添加订阅页）
    var isAutofocused = false

    init(
        _ placeholder: String,
        text: Binding<String>,
        label: String,
        hint: String? = nil,
        kind: Kind = .text,
        isInvalid: Bool = false,
        isAutofocused: Bool = false
    ) {
        self.placeholder = placeholder
        _text = text
        self.label = label
        self.hint = hint
        self.kind = kind
        self.isInvalid = isInvalid
        self.isAutofocused = isAutofocused
    }

    @FocusState private var isFocused: Bool
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    /// 只有窗口拿到 key 才画强调描边：面板刚推入时 SwiftUI 会把默认焦点落到第一个输入框，
    /// 窗口还没激活就画一圈蓝边，看起来像「已经选中」。
    @Environment(\.controlActiveState) private var controlActiveState

    private var isActivelyFocused: Bool {
        isFocused && controlActiveState == .key
    }

    private var font: Font {
        kind == .number ? Typography.number : Typography.body
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, Metrics.fieldInsetH)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            // 用空标题的 TextField + 自绘占位符：系统样式的占位符取不到 text/tertiary
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(font)
                .multilineTextAlignment(kind == .number ? .trailing : .leading)
                .foregroundStyle(isInvalid ? Theme.error : Theme.textPrimary)
                .padding(.horizontal, Metrics.fieldInsetH)
                .focused($isFocused)
        }
        .frame(height: Metrics.fieldHeight)
        .background {
            RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                .fill(Theme.track)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                .strokeBorder(strokeColor, lineWidth: strokeWidth)
        }
        .contentShape(RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous))
        .focusEffectDisabled()
        .opacity(isEnabled ? 1 : 0.6)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onAppear {
            guard isAutofocused else {
                // 窗口把默认焦点落到第一个输入框，还会全选内容：设置页一推入就选中「7890」
                // 既像误触又容易被下一次按键覆盖，这里把这次「白给的焦点」退回去。
                Task { @MainActor in isFocused = false }
                return
            }
            isFocused = true
        }
        .accessibilityLabel(Text(label))
        .accessibilityHint(hint.map(Text.init) ?? Text(""))
    }

    private var strokeColor: Color {
        if isInvalid { return Theme.error }
        if isActivelyFocused { return Theme.accent }
        if isHovering && isEnabled { return Theme.emphasis }
        return Theme.hairline
    }

    private var strokeWidth: CGFloat {
        isInvalid || isActivelyFocused ? Metrics.fieldFocusStroke : Metrics.fieldStroke
    }
}

#if DEBUG
#Preview("输入框四态") {
    @Previewable @State var url = ""
    @Previewable @State var port = "7890"
    @Previewable @State var badPort = "70000"

    VStack(alignment: .leading, spacing: Space.l) {
        PanelTextField("订阅链接（https://…）", text: $url, label: "订阅链接", isAutofocused: true)
        PanelTextField("7890", text: $port, label: "混合端口", kind: .number)
        PanelTextField("7890", text: $badPort, label: "混合端口", hint: "1024–65535", kind: .number, isInvalid: true)
        PanelTextField("留空使用默认", text: $url, label: "自定义 User-Agent")
            .disabled(true)
    }
    .padding(Metrics.cardPadding)
    .frame(width: Metrics.panelWidth)
}
#endif
