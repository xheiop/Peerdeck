import SwiftUI

/// 表单里带标签的输入框：左边标签、右边输入（iOS 的 Form 里 TextField 默认只显示占位文字，填了值以后就看不出是哪一项）
struct FormField: View {
    let label: String
    @Binding var text: String
    var prompt: String = ""
    var secure = false
    var url = false

    init(_ label: String, text: Binding<String>, prompt: String = "", secure: Bool = false, url: Bool = false) {
        self.label = label
        self._text = text
        self.prompt = prompt
        self.secure = secure
        self.url = url
    }

    var body: some View {
        LabeledContent(label) {
            Group {
                // verbatim：占位文字里的网址不要被当成链接（否则显示成蓝色）
                if secure {
                    SecureField(label, text: $text, prompt: Text(verbatim: prompt))
                } else {
                    TextField(label, text: $text, prompt: Text(verbatim: prompt))
                        .keyboardType(url ? .URL : .default)
                }
            }
            .multilineTextAlignment(.trailing)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
    }
}
