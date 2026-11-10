#!/bin/bash
# 同步上游 EarlGrey 2 / eDistantObject 到本仓库。在本地执行，完成后人工检查、提交、打 tag、推送。
#
#   Scripts/sync_upstream.sh                          # 两个上游都取最新
#   Scripts/sync_upstream.sh --earlgrey <commit> --edo <commit>   # 指定版本
#
# 流程：拉上游 → 拷需要的源码进 Vendor/ 并生成 Package.swift → 打 Patches/ 里的补丁
#      → 真机 / 模拟器编译两个 product 验证 → 重建 Binaries/AppFramework.xcframework
#      → 更新 UPSTREAM.lock，并把上游的变更列表追加到 CHANGELOG.md。
# 任一步失败即中止；此时工作区可能是半成品，用 git checkout . && git clean -fd 恢复。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EG_URL="https://github.com/google/EarlGrey.git"
EG_BRANCH="earlgrey2"
EDO_URL="https://github.com/google/eDistantObject.git"
EDO_BRANCH="master"
EG_REF=""
EDO_REF=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --earlgrey) EG_REF="$2"; shift 2 ;;
    --edo) EDO_REF="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 1 ;;
  esac
done

export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8   # xcodeproj gem 读含中文的工程文件需要 UTF-8
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

fetch() {  # fetch <url> <branch> <ref> <dest>
  git clone --quiet --branch "$2" "$1" "$4"
  if [[ -n "$3" ]]; then git -C "$4" checkout --quiet "$3"; fi
}

echo "==> 拉取上游"
fetch "${EG_URL}" "${EG_BRANCH}" "${EG_REF}" "${WORK}/EarlGrey"
fetch "${EDO_URL}" "${EDO_BRANCH}" "${EDO_REF}" "${WORK}/eDistantObject"
EG_NEW="$(git -C "${WORK}/EarlGrey" rev-parse HEAD)"
EDO_NEW="$(git -C "${WORK}/eDistantObject" rev-parse HEAD)"

EG_OLD=""; EDO_OLD=""
if [[ -f "${ROOT}/UPSTREAM.lock" ]]; then
  EG_OLD="$(sed -n 's/^earlgrey_commit=//p' "${ROOT}/UPSTREAM.lock")"
  EDO_OLD="$(sed -n 's/^edistantobject_commit=//p' "${ROOT}/UPSTREAM.lock")"
fi
echo "    EarlGrey        ${EG_OLD:-（无）} -> ${EG_NEW}"
echo "    eDistantObject  ${EDO_OLD:-（无）} -> ${EDO_NEW}"

echo "==> 拷贝源码并生成 Package.swift"
ruby "${ROOT}/Scripts/vendor_and_generate.rb" "${WORK}/EarlGrey" "${WORK}/eDistantObject"

shopt -s nullglob
patches=("${ROOT}"/Patches/*.patch)
if (( ${#patches[@]} > 0 )); then
  echo "==> 应用 Patches/（${#patches[@]} 个）"
  for p in "${patches[@]}"; do
    echo "    $(basename "$p")"
    git -C "${ROOT}" apply --whitespace=nowarn "$p"
  done
fi

echo "==> 编译验证（EarlGreyTest / AppFramework × 真机 / 模拟器）"
cd "${ROOT}"
for scheme in EarlGreyTest AppFramework; do
  for platform in "iOS" "iOS Simulator"; do
    xcodebuild build -scheme "${scheme}" -destination "generic/platform=${platform}" \
      -derivedDataPath "${WORK}/verify" CODE_SIGNING_ALLOWED=NO -quiet
    echo "    ${scheme} / ${platform} 通过"
  done
done

echo "==> 重建 AppFramework.xcframework"
"${ROOT}/Scripts/build_xcframework.sh"

cat > "${ROOT}/UPSTREAM.lock" <<EOF
# 由 Scripts/sync_upstream.sh 写入，记录 Vendor/ 对应的上游版本
earlgrey_repo=${EG_URL}
earlgrey_branch=${EG_BRANCH}
earlgrey_commit=${EG_NEW}
edistantobject_repo=${EDO_URL}
edistantobject_branch=${EDO_BRANCH}
edistantobject_commit=${EDO_NEW}
synced_at=$(date +%Y-%m-%d)
EOF

changes() {  # changes <repo dir> <old> <new>
  if [[ -n "$2" && "$2" != "$3" ]] && git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null; then
    git -C "$1" log --no-merges --format='- %h %s' "$2..$3"
  elif [[ -z "$2" ]]; then
    echo "- 初始导入 ${3:0:10}"
  fi
  return 0
}
EG_LOG="$(changes "${WORK}/EarlGrey" "${EG_OLD}" "${EG_NEW}")"
EDO_LOG="$(changes "${WORK}/eDistantObject" "${EDO_OLD}" "${EDO_NEW}")"
{
  echo "## 同步 $(date +%Y-%m-%d)"
  echo
  echo "EarlGrey \`${EG_OLD:0:10}\` → \`${EG_NEW:0:10}\`"
  echo
  echo "${EG_LOG:-- 无变化}"
  echo
  echo "eDistantObject \`${EDO_OLD:0:10}\` → \`${EDO_NEW:0:10}\`"
  echo
  echo "${EDO_LOG:-- 无变化}"
  echo
  if [[ -f "${ROOT}/CHANGELOG.md" ]]; then sed '1,2d' "${ROOT}/CHANGELOG.md"; fi
} > "${WORK}/CHANGELOG.new"
{ echo "# 上游同步记录"; echo; cat "${WORK}/CHANGELOG.new"; } > "${ROOT}/CHANGELOG.md"

echo
echo "==> 完成。接下来："
echo "    git -C \"${ROOT}\" status                # 检查改动"
echo "    git -C \"${ROOT}\" add -A && git -C \"${ROOT}\" commit -m \"Sync upstream ${EG_NEW:0:10}\""
echo "    git -C \"${ROOT}\" tag <新版本号> && git -C \"${ROOT}\" push origin main --tags"
echo "    主工程在 Xcode 里把 tvu-app-earlgrey-testcase 的版本改成新 tag"
