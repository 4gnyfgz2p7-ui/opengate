#!/usr/bin/env bash
# 界面层与采集层的隔离门禁。
#
# 目的很具体：界面只允许「表达意图」（改控制器属性、调引擎方法），
# 不允许自己伸出手去摸设备或写入器。摸设备是主线程卡顿与录制失败的
# 历史来源，一旦散进视图里，下次再出问题就又是一次全网搜索。
#
# 覆盖三块：横屏界面、竖屏界面、两边共用的控件层。
set -u

DIRS="Sources/Landscape Sources/Portrait Sources/Controls"
FORBIDDEN='lockForConfiguration|setExposureModeCustom|setWhiteBalanceModeLocked|setFocusModeLocked|AVAssetWriter|MovieRecorder|AVCaptureDeviceInput|startRunning|stopRunning'

failed=0
for DIR in $DIRS; do
    if [ ! -d "$DIR" ]; then
        echo "隔离检查：跳过（$DIR 不存在）"
        continue
    fi
    if grep -rnE "$FORBIDDEN" "$DIR" --include='*.swift'; then
        echo ""
        echo "隔离检查失败：$DIR 直接碰了设备或写入器。"
        echo "界面只能调 RecordingEngine / 控制器的公开接口。"
        failed=1
    fi
done

if [ "$failed" -ne 0 ]; then
    exit 1
fi

echo "隔离检查通过：横屏 / 竖屏 / 共用控件均未直接操作设备与写入器"
