import SwiftUI

@main
struct OpenGateApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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

/// 界面方向的唯一裁决点。
///
/// 运行期支持的方向永远只有一个——当前拍摄方向对应的那个；
/// Info.plist 仍声明四个方向，作为运行期可申请的超集。
/// 没有这层锁，物理转机身会触发系统自转，与方向键的
/// `requestGeometryUpdate` 互相打架，旋转动画被打断后
/// 根视图 transform 卡死，整层控件横躺（实测截图里的 90° 错乱来源）。
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// 运行期支持面的初值必须和落盘的选择一致。
    /// 先设成 portrait 再靠 requestGeometryUpdate 转过去，会在启动瞬间闪一帧竖屏，
    /// 甚至被根 VC 的缓存判成「不支持横屏」——这就是之前「怎么都切不到横屏」的来源。
    static var supportedMask: UIInterfaceOrientationMask = InterfaceMode.saved.mask

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Self.supportedMask = InterfaceMode.saved.mask
        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.supportedMask
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
