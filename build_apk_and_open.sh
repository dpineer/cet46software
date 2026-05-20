#!/bin/bash
# ============================================================
# 一键编译 Flutter Release APK 并在 XFCE 文件管理器中打开
# ============================================================

set -e

echo "============================================"
echo "  开始编译 Flutter Release APK..."
echo "============================================"

# 记录开始时间
START_TIME=$(date +%s)

# 执行 flutter build apk --release
if flutter build apk --release; then
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    MINUTES=$((DURATION / 60))
    SECONDS=$((DURATION % 60))

    echo ""
    echo "============================================"
    echo "  ✅ APK 编译成功！"
    echo "  耗时: ${MINUTES}分${SECONDS}秒"
    echo "============================================"

    # APK 文件路径
    APK_DIR="build/app/outputs/flutter-apk"
    APK_FILE="$APK_DIR/app-release.apk"

    if [ -f "$APK_FILE" ]; then
        # 获取文件大小
        FILE_SIZE=$(ls -lh "$APK_FILE" | awk '{print $5}')
        echo "  📦 APK 文件: $APK_FILE"
        echo "  📏 文件大小: $FILE_SIZE"
    fi

    echo ""
    echo "即将在文件管理器中打开 APK 目录..."

    # 尝试多种方式在 XFCE 的文件管理器中打开目录
    # 方式1: xdg-open (最通用)
    if command -v xdg-open &> /dev/null; then
        xdg-open "$APK_DIR" &
        echo "  ✅ 已通过 xdg-open 打开文件管理器"
    # 方式2: thunar (XFCE 原生)
    elif command -v thunar &> /dev/null; then
        thunar "$APK_DIR" &
        echo "  ✅ 已通过 Thunar 打开文件管理器"
    # 方式3: 兜底，使用 nautilus 或 dolphin 等
    elif command -v nautilus &> /dev/null; then
        nautilus "$APK_DIR" &
        echo "  ✅ 已通过 Nautilus 打开文件管理器"
    elif command -v dolphin &> /dev/null; then
        dolphin "$APK_DIR" &
        echo "  ✅ 已通过 Dolphin 打开文件管理器"
    else
        echo "  ⚠️  未找到图形化文件管理器，请手动打开目录:"
        echo "     $(realpath "$APK_DIR")"
    fi

    echo ""
    echo "============================================"
    echo "  完成！"
    echo "============================================"
else
    echo ""
    echo "============================================"
    echo "  ❌ APK 编译失败！"
    echo "  请检查上方错误信息"
    echo "============================================"
    exit 1
fi