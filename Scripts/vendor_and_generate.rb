#!/usr/bin/env ruby
# frozen_string_literal: true
#
# 由 sync_upstream.sh 调用，不单独执行。
# 1. 从上游 EarlGrey.xcodeproj / eDistantObject.xcodeproj 读出每个 target 实际编译的源文件；
# 2. 只把需要的源码与头文件拷进 Vendor/（上游的 Tests、Demo、xcodeproj 一律不带）；
# 3. 生成 Package.swift。
#
#   ruby vendor_and_generate.rb <EarlGrey 上游目录> <eDistantObject 上游目录>
#
# 为什么要按 xcodeproj 生成而不是手写：
# - 上游不按目录划分 target（AppFramework 会编 TestLib 下的文件，TestLib 也会编 AppFramework 下的文件），
#   SPM 只能用显式 sources 列表还原；
# - 上游 import 是扁平写法（"GREYActions.h"），依赖递归头文件搜索，SPM 不支持递归，需要逐个列目录。
# 依赖：xcodeproj gem（CocoaPods 自带）。

require 'xcodeproj'
require 'fileutils'

EG_SRC = File.expand_path(ARGV.fetch(0) { abort('用法：vendor_and_generate.rb <EarlGrey 目录> <eDistantObject 目录>') })
EDO_SRC = File.expand_path(ARGV.fetch(1) { abort('缺少 eDistantObject 目录参数') })
PKG_ROOT = File.expand_path('..', __dir__)
EG_DIR = 'Vendor/EarlGrey'
EDO_DIR = 'Vendor/eDistantObject'
EG_LIBS = %w[AppFramework CommonLib UILib TestLib].freeze

# 返回 { target 名 => [相对上游根目录的源文件] }
def sources_of(upstream_root, project_name, target_names)
  project = Xcodeproj::Project.open(File.join(upstream_root, project_name))
  target_names.to_h do |name|
    target = project.targets.find { |t| t.name == name } or abort("找不到 target #{name}（#{project_name}）")
    files = target.source_build_phase.files.map { |f| f.file_ref.real_path.to_s.delete_prefix("#{upstream_root}/") }
    [name, files.sort]
  end
end

def copy_into(src_root, rel_paths, dest_root)
  rel_paths.each do |rel|
    dest = File.join(dest_root, rel)
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.cp(File.join(src_root, rel), dest)
  end
end

def headers_under(root, dirs)
  dirs.flat_map do |d|
    Dir.glob('**/*.h', base: File.join(root, d)).map { |h| File.join(d, h) }
  end
end

eg = sources_of(EG_SRC, 'EarlGrey.xcodeproj', %w[CommonLib UILib AppFramework TestLib])
edo = sources_of(EDO_SRC, 'eDistantObject.xcodeproj', %w[eDistantObject ChannelLib MeasureLib DeviceLib])

# ---------- 1. 拷源码 ----------
Dir.chdir(PKG_ROOT)
FileUtils.rm_rf('Vendor')
eg_files = eg.values.flatten.uniq + headers_under(EG_SRC, EG_LIBS + ['third_party/fishhook']) + ['LICENSE']
edo_src_dirs = Dir.glob('*/Sources', base: EDO_SRC).sort
edo_files = edo.values.flatten.uniq + headers_under(EDO_SRC, edo_src_dirs) + ['LICENSE']
copy_into(EG_SRC, eg_files.uniq, EG_DIR)
copy_into(EDO_SRC, edo_files.uniq, EDO_DIR)

# ---------- 2. 生成 Package.swift ----------
prefix = ->(dir, files) { files.map { |f| "#{dir}/#{f}" } }

# 同时被 AppFramework 与 TestLib 编译的文件（两个进程各需一份）。SPM 不允许一个文件属于两个 target，
# 所以抽成独立的 EarlGreyShared target，由两边分别依赖、各自链接一份。
# 它只能依赖 CommonLib（与上游 TestLib 一致）：若依赖 UILib，测试端会和 app 端一样链进 UILib，
# Xcode 把 SPM target 预链接成 .o 时会出现 GREYScreenshotter 等重复符号。
shared = eg['AppFramework'] & eg['TestLib']
app_only = eg['AppFramework'] - shared
test_only = eg['TestLib'] - shared
edo_all = edo.values.flatten.uniq.sort

# 扁平 import 需要的头文件目录：EarlGrey 各库所有含头文件的目录 + EarlGrey 根（"CommonLib/..." 式写法），
# eDO 根（"Service/Sources/..." 式写法）+ 各 Sources 目录（EarlGrey 里的 "EDOHostService.h" 式写法）。
eg_dirs = Dir.glob("#{EG_DIR}/**/*.h").map { |h| File.dirname(h) }.uniq.sort
eg_dirs = [EG_DIR] + eg_dirs
edo_dirs = [EDO_DIR] + edo_src_dirs.map { |d| "#{EDO_DIR}/#{d}" }

# 所有 target 的 path 都是包根（"."）：SPM 要求 publicHeadersPath 是 target 内真实存在的目录，
# 用包根做 path 后每个 target 放一个空的 include/<Target>/ 即可。代价是包根下的其它文件都要 exclude，
# 否则会被当成资源（Binaries 里的 xcframework、脚本、文档）。
TARGET_NAMES = %w[eDistantObject EarlGreyCommonLib EarlGreyUILib EarlGreyShared EarlGreyAppLib EarlGreyTestLib].freeze
TARGET_NAMES.each do |t|
  FileUtils.mkdir_p("include/#{t}")
  File.write("include/#{t}/.gitkeep", '')
end
FileUtils.mkdir_p('Binaries')
FileUtils.mkdir_p('Patches')
top_level = Dir.children('.').reject { |e| e.start_with?('.') || %w[Vendor include Package.swift].include?(e) }.sort
excludes = top_level + Dir.glob('Vendor/**/*').select { |f| File.file?(f) && !f.end_with?('.h', '.m', '.c') }.sort

def swift_list(items, indent)
  items.map { |i| "#{' ' * indent}\"#{i}\"," }.join("\n")
end

def target_block(name, files, deps, header_var, extra = nil)
  lines = []
  lines << '    .target('
  lines << "      name: \"#{name}\","
  lines << "      dependencies: [#{deps.map { |d| "\"#{d}\"" }.join(', ')}]," unless deps.empty?
  lines << '      path: ".",'
  lines << '      exclude: excluded,'
  lines << '      sources: ['
  lines << swift_list(files, 8)
  lines << '      ],'
  lines << "      publicHeadersPath: \"include/#{name}\","
  lines << "      cSettings: #{header_var}#{extra ? ',' : ''}"
  lines << "      #{extra}" if extra
  lines << '    ),'
  lines.join("\n")
end

manifest = <<~SWIFT
  // swift-tools-version:5.9
  // ⚠️ 本文件由 Scripts/sync_upstream.sh 生成，不要手改。
  //
  // EarlGrey 2（earlgrey2 分支）+ eDistantObject 的 SPM 封装，上游版本见 UPSTREAM.lock。
  // - EarlGreyTest：静态库，只链接到 UI Test target（测试进程）。
  // - AppFramework：动态库，仅供 Scripts/build_xcframework.sh 产出 Binaries/AppFramework.xcframework。
  //   绝不能链接到任何 target：由使用方 UI Test target 的 Run Script（Scripts/embed_app_framework.sh）
  //   在测试编译时拷进被测 app 的 Frameworks/，启动时 TestLib 经 DYLD_INSERT_LIBRARIES 注入。
  //   名字必须叫 AppFramework，路径写死在上游 TestLib/XCTestCase/XCUIApplication+GREYEnvironment.m。
  import PackageDescription

  let earlGreyHeaders: [CSetting] = [
  #{(eg_dirs + edo_dirs).uniq.map { |d| "  .headerSearchPath(\"#{d}\")," }.join("\n")}
  ]

  let eDOHeaders: [CSetting] = [
  #{edo_dirs.map { |d| "  .headerSearchPath(\"#{d}\")," }.join("\n")}
  ]

  let excluded: [String] = [
  #{swift_list(excludes, 2)}
  ]

  let package = Package(
    name: "TVUEarlGrey",
    platforms: [.iOS(.v15)],
    products: [
      .library(name: "EarlGreyTest", type: .static, targets: ["EarlGreyTestLib"]),
      .library(name: "AppFramework", type: .dynamic, targets: ["EarlGreyAppLib"]),
    ],
    targets: [
  #{target_block('eDistantObject', edo_all.map { |f| "#{EDO_DIR}/#{f}" }, [], 'eDOHeaders')}
  #{target_block('EarlGreyCommonLib', prefix.(EG_DIR, eg['CommonLib']), ['eDistantObject'], 'earlGreyHeaders')}
  #{target_block('EarlGreyUILib', prefix.(EG_DIR, eg['UILib']), ['EarlGreyCommonLib'], 'earlGreyHeaders')}
  #{target_block('EarlGreyShared', prefix.(EG_DIR, shared), ['EarlGreyCommonLib'], 'earlGreyHeaders')}
  #{target_block('EarlGreyAppLib', prefix.(EG_DIR, app_only),
                 %w[EarlGreyShared EarlGreyUILib EarlGreyCommonLib eDistantObject], 'earlGreyHeaders',
                 'linkerSettings: [.linkedFramework("IOKit")]')}
  #{target_block('EarlGreyTestLib', prefix.(EG_DIR, test_only),
                 %w[EarlGreyShared EarlGreyCommonLib eDistantObject], 'earlGreyHeaders',
                 'linkerSettings: [.linkedFramework("XCTest")]')}
    ]
  )
SWIFT

File.write('Package.swift', manifest)
puts "已拷贝 Vendor/ 并生成 Package.swift：eDO #{edo_all.size}，Common #{eg['CommonLib'].size}，" \
     "UI #{eg['UILib'].size}，Shared #{shared.size}，App #{app_only.size}，Test #{test_only.size}，" \
     "头文件目录 #{(eg_dirs + edo_dirs).uniq.size}"
