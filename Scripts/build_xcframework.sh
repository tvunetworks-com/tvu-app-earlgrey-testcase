#!/bin/bash
# 把 AppFramework（EarlGrey 的 app 端）编成 Binaries/AppFramework.xcframework（真机 + 模拟器）。
# 由 sync_upstream.sh 调用；只改了 Patches/ 想重出二进制时也可单独执行。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Release}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

cd "${ROOT}"
for platform in "iOS" "iOS Simulator"; do
  echo "==> 编译 AppFramework（${platform}，${CONFIGURATION}）"
  xcodebuild build \
    -scheme AppFramework \
    -destination "generic/platform=${platform}" \
    -configuration "${CONFIGURATION}" \
    -derivedDataPath "${WORK}/dd" \
    CODE_SIGNING_ALLOWED=NO \
    -quiet
done

PRODUCTS="${WORK}/dd/Build/Products"
rm -rf Binaries/AppFramework.xcframework
mkdir -p Binaries
xcodebuild -create-xcframework \
  -framework "${PRODUCTS}/${CONFIGURATION}-iphoneos/PackageFrameworks/AppFramework.framework" \
  -framework "${PRODUCTS}/${CONFIGURATION}-iphonesimulator/PackageFrameworks/AppFramework.framework" \
  -output Binaries/AppFramework.xcframework
echo "==> 已生成 Binaries/AppFramework.xcframework"
