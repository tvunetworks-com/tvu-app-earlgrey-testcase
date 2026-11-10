# tvu-app-earlgrey-testcase

本仓库把 [EarlGrey 2](https://github.com/google/EarlGrey/tree/earlgrey2)（`earlgrey2` 分支）及其依赖 [eDistantObject](https://github.com/google/eDistantObject) 封装成 Swift Package，供 TVU 的 iOS 工程做 UI 自动化测试。

上游这两个仓库都没有提供 Package.swift，所以本仓库的做法是：把需要的源码拷进 `Vendor/`，再由脚本生成 `Package.swift`。同步上游、编译验证、打包二进制都在本地执行一个脚本即可完成。

## 目录

| 路径 | 说明 |
|---|---|
| `Vendor/EarlGrey/`、`Vendor/eDistantObject/` | 上游源码，只保留编译需要的 `.h`、`.m`、`.c` 和 LICENSE。**不要手改**，要改请用 `Patches/` |
| `Patches/*.patch` | 本仓库对上游的修改，每次同步后按文件名顺序自动重新打上 |
| `Package.swift` | 生成文件，不要手改 |
| `Binaries/AppFramework.xcframework` | EarlGrey 的 app 端产物，包含真机和模拟器两个切片，由同步脚本生成 |
| `UPSTREAM.lock` | 当前 `Vendor/` 对应的上游 commit |
| `CHANGELOG.md` | 每次同步时上游的 commit 列表 |
| `Scripts/sync_upstream.sh` | 同步上游，见下文 |
| `Scripts/embed_app_framework.sh` | 使用方 UI Test target 的 Run Script |

## 两个 product

- **`EarlGreyTest`**（静态库）：链接到 UI Test target，运行在测试进程。
- **`AppFramework`**（动态库）：只用来生成 xcframework。**不要链接到任何 target。**
  - 挂到 app target 上，Release 包也会带上并加载 EarlGrey。
  - 挂到 UI Test target 上，它会被嵌进测试 runner 进程。

## 使用方接入（以 TVUIRL 为例）

在 Xcode 中通过 File → Add Package Dependencies 添加本仓库：
- 地址用 `https://github.com/tvunetworks-com/tvu-app-earlgrey-testcase.git`
- 版本规则选 **Exact Version**
- 只把 `EarlGreyTest` 加到 UI Test target

然后在 UI Test target 上做以下配置：

| 配置项 | 值 |
|---|---|
| `EARLGREY_PKG_DIR` | `$(BUILD_DIR)/../../SourcePackages/checkouts/tvu-app-earlgrey-testcase` |
| `HEADER_SEARCH_PATHS` | `$(EARLGREY_PKG_DIR)/Vendor/EarlGrey`，加上 `$(EARLGREY_PKG_DIR)/Vendor/EarlGrey/{AppFramework,CommonLib,TestLib,UILib}/**`，加上 `$(EARLGREY_PKG_DIR)/Vendor/eDistantObject` 及其 `{Channel,Device,Measure,Service}/Sources` |
| `OTHER_LDFLAGS` | `$(inherited) -ObjC` |
| `ENABLE_USER_SCRIPT_SANDBOXING` | `NO` |
| Run Script | `"${EARLGREY_PKG_DIR}/Scripts/embed_app_framework.sh" "TVU Go.app"` |

关于 `EARLGREY_PKG_DIR`：
- 这个路径是 Xcode 和 xcodebuild 默认的 SPM 下载位置。如果 xcodebuild 用了 `-clonedSourcePackagesDirPath`，要把它改成对应目录。
- 头文件路径用 Xcode 变量拼接，不同机器上都能用，不需要写死绝对路径。

用例里 `#import "TestLib/EarlGrey.h"`。写法见 TVUIRL 工程的 `documents/features/ui_testing/EARLGREY2.md`。

## 同步上游（本地执行）

```bash
Scripts/sync_upstream.sh                                   # 两个上游都取最新
Scripts/sync_upstream.sh --earlgrey <commit> --edo <commit>  # 指定版本
```

脚本依次做这些事：
1. 拉取上游。
2. 拷贝源码到 `Vendor/`，并生成 `Package.swift`。
3. 应用 `Patches/` 里的补丁。
4. 在真机和模拟器两个平台上编译 `EarlGreyTest` 和 `AppFramework`，验证能编过。
5. 重建 `Binaries/AppFramework.xcframework`。
6. 更新 `UPSTREAM.lock` 和 `CHANGELOG.md`。

脚本执行完之后，人工完成剩下的步骤：

```bash
git add -A && git commit -m "Sync upstream <earlgrey 短 commit>"
git tag <版本号>          # 语义化版本，如 1.1.0；上游 commit 已记在 UPSTREAM.lock
git push origin main --tags
```

最后在使用方工程里，把本包的版本号改成新 tag。

依赖工具：Xcode、ruby，以及 `xcodeproj` gem（随 CocoaPods 一起安装）。

### 补丁

需要修改上游代码时，按以下步骤操作：
1. 在 `Vendor/` 里改好。
2. 执行 `git diff > Patches/NNN-说明.patch` 导出补丁。
3. 执行 `git checkout Vendor` 撤销 `Vendor/` 里的改动。
4. 重新执行同步脚本，或者只执行 `Scripts/build_xcframework.sh`。

补丁里新增的源文件不会进入 `Package.swift` 的编译清单，因为清单是从上游 xcodeproj 读出来的。所以补丁只适合修改已有文件。

## 许可证

`Vendor/` 下的代码来自 Google 的 EarlGrey 和 eDistantObject，使用 Apache License 2.0，原 LICENSE 文件保留在各自目录下。
