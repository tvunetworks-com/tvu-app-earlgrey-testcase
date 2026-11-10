#!/bin/bash
# 使用方 UI Test target 的 Run Script：把 Binaries/AppFramework.xcframework 中当前平台的切片拷进被测 app 的
# Frameworks/ 并签名。启动时 TestLib 设置
#   DYLD_INSERT_LIBRARIES=@executable_path/Frameworks/AppFramework.framework/AppFramework
# 把它注入 app 进程。
#
# 在 UI Test target 中配置：
#   - 构建设置 EARLGREY_PKG_DIR = $(BUILD_DIR)/../../SourcePackages/checkouts/tvu-app-earlgrey-testcase
#     （Xcode / xcodebuild 默认的 SPM 下载位置；用了 -clonedSourcePackagesDirPath 时改成对应目录）
#   - ENABLE_USER_SCRIPT_SANDBOXING = NO（要写入被测 app 包）
#   - Run Script：  "${EARLGREY_PKG_DIR}/Scripts/embed_app_framework.sh" "<被测 app>.app"
#
# 为什么不把 AppFramework 直接挂到某个 target：
# - 挂到 app target：Release / 上架包也会带上并加载 EarlGrey；
# - 挂到 UI Test target：会被嵌进测试 runner，在 runner 进程里跑 EarlGrey 的 app 端初始化。
# 真机上 DYLD_* 只对开发签名（get-task-allow）的包生效，分发包即使残留也不会加载。
set -euo pipefail

APP_WRAPPER="${1:?需要传入被测 app 的包名，例如 \"TVU Go.app\"}"
PKG_DIR="${EARLGREY_PKG_DIR:-${BUILD_DIR}/../../SourcePackages/checkouts/tvu-app-earlgrey-testcase}"
XCFW="${PKG_DIR}/Binaries/AppFramework.xcframework"
APP_DIR="${BUILT_PRODUCTS_DIR}/${APP_WRAPPER}"

[[ -d "${XCFW}" ]] || { echo "error: 找不到 ${XCFW}，检查构建设置 EARLGREY_PKG_DIR" >&2; exit 1; }
[[ -d "${APP_DIR}" ]] || { echo "error: 找不到被测 app：${APP_DIR}（UI Test target 应依赖 app target）" >&2; exit 1; }

SLICE=""
for d in "${XCFW}"/ios-*; do
  [[ -d "$d" ]] || continue
  case "$(basename "$d")" in
    *-simulator) is_sim=1 ;;
    *) is_sim=0 ;;
  esac
  if [[ "${PLATFORM_NAME}" == "iphonesimulator" && ${is_sim} == 1 ]] ||
     [[ "${PLATFORM_NAME}" == "iphoneos" && ${is_sim} == 0 ]]; then
    SLICE="$d/AppFramework.framework"
    break
  fi
done
[[ -n "${SLICE}" && -d "${SLICE}" ]] || { echo "error: xcframework 中没有 ${PLATFORM_NAME} 切片" >&2; exit 1; }

DEST_DIR="${APP_DIR}/Frameworks"
mkdir -p "${DEST_DIR}"
rm -rf "${DEST_DIR}/AppFramework.framework"
cp -R "${SLICE}" "${DEST_DIR}/"

SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ -z "${SIGN_IDENTITY}" || "${CODE_SIGNING_ALLOWED:-YES}" == "NO" ]]; then
  SIGN_IDENTITY="-"
fi
/usr/bin/codesign --force --sign "${SIGN_IDENTITY}" --timestamp=none "${DEST_DIR}/AppFramework.framework"
echo "note: 已注入 AppFramework.framework -> ${DEST_DIR}（签名身份：${SIGN_IDENTITY}）"
