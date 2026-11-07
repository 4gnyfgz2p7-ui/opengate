import SwiftUI

@main
struct OpenGateApp: App {

    init() {
        // 必须最早安装：AVFoundation 抛的是 ObjC 异常，Swift 接不住，
        // 只有在进程终止前把原因写进文件，下次打开才有据可查。
        Diagnostics.installExceptionHandler()
    }

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
