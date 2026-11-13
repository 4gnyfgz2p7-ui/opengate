#!/usr/bin/env bash
# 横屏界面与采集层的隔离门禁。
#
# 目的很具体：界面只允许「表达意图」（改控制器属性、调引擎方法），
# 不允许自己伸出手去摸设备或写入器。摸设备是主线程卡顿与录制失败的
# 历史来源，一旦散进视图里，下次再出问题就又是一次全网搜索。
set -u
DIR="Sources/Landscape"
if [ ! -d "$DIR" ]; then
    echo "隔离检查：跳过（$DIR 不存在）"
    exit 0
fi

FORBIDDEN='lockForConfiguration|setExposureModeCustom|setWhiteBalanceModeLocked|setFocusModeLocked|AVAssetWriter|MovieRecorder|AVCaptureDeviceInput|startRunning|stopRunning'
if grep -rnE "$FORBIDDEN" "$DIR" --include='*.swift'; then
    echo ""
    echo "隔离检查失败：Sources/Landscape 直接碰了设备或写入器。"
    echo "界面只能调 RecordingEngine / 控制器的公开接口。"
    exit 1
fi

echo "隔离检查通过：Sources/Landscape 未直接操作设备与写入器"
