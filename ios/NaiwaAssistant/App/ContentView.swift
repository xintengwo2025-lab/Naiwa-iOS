import SwiftUI

/// 最简启动视图（占位）。
/// 后续在此挂载 GameWebViewHolder 的 webView 承载游戏主界面。
struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("NaiwaAssistant")
                .font(.title)
            Text("奶蛙")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}
