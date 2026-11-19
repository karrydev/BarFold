# BarFold

BarFold 是免费的 macOS 菜单栏整理工具。把不常用的图标收到菜单栏的 `…` 下，需要时再叫出来。它继承自 [Thaw 2.1.0](https://github.com/thaw-app/Thaw/tree/2.1.0)（基线 `c5ec133`），Thaw 又继承自 [Ice](https://github.com/jordanbaird/Ice)。BarFold 独立维护，与 iBar、Thaw 和 Ice 的开发团队无隶属关系。

![BarFold 图标](docs/artwork/BarFold.svg)

## 使用

1. **启动**：在 macOS 26 上打开 `BarFold.app`。首次启动按引导打开「系统设置 → 隐私与安全性」，为 BarFold 开启**辅助功能**以移动菜单栏项目、打开原菜单。开启**屏幕与系统音频录制**权限以显示原生菜单栏图标；未取得图像时显示可识别的占位符，不用应用 Logo 冒充。
2. **收起或保留图标**：右键菜单栏的 `…` 打开设置，进入「布局」，在「显示」和「隐藏」之间拖动图标，或在同一区域拖动排序。「布局」里的图标只用于拖动，点击不会打开应用或菜单。图标太多时，可用滚轮或触控板横向浏览。
3. **使用隐藏的图标**：左键点击菜单栏的 `…`，隐藏图标会出现在下方的横排托盘。点击托盘内的图标可打开原应用的菜单或执行该图标原有的动作。点托盘末尾的齿轮可打开设置。
4. **预览**：启动后预先获取菜单栏图标，布局和托盘共用真实图像。「布局」打开时，会低频更新可见的动态图标（例如网速）；关闭后停止。macOS 无法提供某个图标画面时，仍可用占位符操作它。

建议先退出其他菜单栏整理工具，避免两个应用同时移动图标。不需要先卸载原来的工具。双屏和刘海区域的排列受 macOS 限制，某些系统图标不能移动，第三方菜单的位置也由其原应用控制。

## 构建与部署

要求：**macOS 26、Xcode 26.3 或更新版本**。首次构建需要网络来下载 Swift Package 依赖。实际在 Apple Silicon Mac 上验证；不承诺其他 macOS 版本或硬件组合。

```sh
git clone https://github.com/karrydev/BarFold.git
cd BarFold
./scripts/build-barfold-local.sh
```

脚本在 `build/BarFold.app` 生成并验证本机 ad hoc 签名的应用，不会自动启动或安装。先退出任何旧的 BarFold 进程，再把新应用移到一个固定路径（例如 `~/Applications/BarFold.app`）并打开；替换前建议保留旧版。也可以在 Xcode 打开 `Thaw.xcodeproj`，选择保留的 **Thaw** scheme 构建，产品显示名仍是 BarFold。

本机 ad hoc 签名不需要 Apple 开发者账号，但重新构建后 macOS 可能要求重新授予权限。若想让同一台 Mac 的权限尽量随升级沿用，可用自己已配置的 Apple Development 签名：主应用和两个 XPC 服务必须使用同一签名团队，且保留项目中的 Bundle Identifier。不要提交证书、私钥、签名团队配置或本机签名产物。对其他人分发签名、打包和公证是独立工作；这个脚本不绕过 Gatekeeper，也不生成公证发布包。

BarFold 不连接 Thaw 的自动更新源。更新时，从本仓库获取新代码并重新构建、替换应用。

## 开源许可与修改声明

BarFold 源码采用 [GNU General Public License, version 3](LICENSE)（GPL-3.0）；保留 Ice 与 Thaw 的版权、许可及无担保声明。分发修改版或二进制时，请保留这些声明并按 GPLv3 提供对应源代码。第三方依赖各自适用其许可证，详见 [第三方声明](Thaw/Resources/Acknowledgements.md) 与 [贡献者名单](CREDITS.md)。

BarFold 在 **2026-11-19** 基于上述 Thaw 版本修改：更换名称、应用图标和独立应用标识，默认采用三点入口和横排托盘；调整布局拖放、指针恢复、原生图标预加载与布局动态预览；保留原生图标的菜单路由并加入托盘设置入口；停用上游更新源。上游变更记录保留在 [CHANGELOG.md](CHANGELOG.md)。

The project is an independent, GPLv3-licensed fork of Thaw (itself based on Ice). Build locally with Xcode 26.3+ on macOS 26. No upstream automatic update feed is used.
