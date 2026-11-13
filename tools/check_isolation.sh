#!/usr/bin/env bash
# 边界检查：Sources/Color/ 只做色彩还原，不许引用 Sources/Capture/ 里的类型。
#
# 为什么要有这一步：颜色映射（Apple Log 2 曲线 + 高光肩 + 阴影 gamma + LUT）
# 是反复验证过、要长期保持不变的一段；拍摄那侧（采集、曝光、录制）改坏了
# 不能顺带把它拖下水。规矩写在这里，CI 每次构建都查一遍，不靠记性。
#
# 反方向允许：拍摄、界面都可以调 Sources/Color/ 的接口。
set -u

cd "$(dirname "$0")/.." || exit 2

COLOR_DIR="Sources/Color"
CAPTURE_DIR="Sources/Capture"

if [ ! -d "$COLOR_DIR" ] || [ ! -d "$CAPTURE_DIR" ]; then
    echo "找不到 $COLOR_DIR 或 $CAPTURE_DIR"
    exit 2
fi

# 采集侧声明的顶层类型（class / struct / enum / protocol / actor）。
# 只认顶格的声明：缩进的是嵌套类型，名字太短太常见（Mode / Path），
# 拿来做判据只会误报。
types=$(grep -hoE '^(public |internal |private |fileprivate |final |@MainActor )*(class|struct|enum|protocol|actor) [A-Za-z_][A-Za-z0-9_]*' \
            "$CAPTURE_DIR"/*.swift \
        | sed -E 's/.*(class|struct|enum|protocol|actor) //' \
        | sort -u)

if [ -z "$types" ]; then
    echo "没能从 $CAPTURE_DIR 提取到类型名，检查脚本本身"
    exit 2
fi

violations=0
for name in $types; do
    hits=$(grep -n "\b${name}\b" "$COLOR_DIR"/*.swift || true)
    if [ -n "$hits" ]; then
        echo "越界：$COLOR_DIR 引用了采集侧类型 $name"
        echo "$hits" | sed 's/^/    /'
        violations=$((violations + 1))
    fi
done

# 顺手挡一道：颜色链路不许自己去锁设备
if grep -n "lockForConfiguration" "$COLOR_DIR"/*.swift >/dev/null 2>&1; then
    echo "越界：$COLOR_DIR 里出现了 lockForConfiguration，颜色链路不该碰设备"
    violations=$((violations + 1))
fi

if [ "$violations" -ne 0 ]; then
    echo "隔离检查失败：$violations 处越界"
    exit 1
fi

echo "隔离检查通过：$COLOR_DIR 未引用 $CAPTURE_DIR 的任何类型（扫描 $(echo "$types" | wc -l | tr -d ' ') 个）"
