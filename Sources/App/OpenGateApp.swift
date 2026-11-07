import SwiftUI

@main
struct OpenGateApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}

/// 录制主界面与探针页的切换。
/// 探针不再放进 Tab——它是诊断工具，不是日常入口。
struct RootView: View {
    @State private var showProbe = false

    var body: some View {
        Group {
            if showProbe {
                ContentView(onClose: { showProbe = false })
            } else {
                RecorderView(onShowProbe: { showProbe = true })
            }
        }
    }
}
