# DongtuCam · 拍完即出片

打开就是相机，点一次快门：录 5 秒 → 自动匹配商品文案 → 逐帧烧录 → 直接写回相册成一张实况照片（Live Photo）。全程无电脑、无合成工具、无手动导入。

## 目录

- `Sources/` —— SwiftUI 主界面 + 相机录制 + 文案引擎 + 逐帧烧录 + PhotoKit 实况写入
- `Resources/products.json` —— 离线商品库（可自行增删）
- `Resources/rules.json` —— 三段式文案规则（具体的人 + 已发生的变化 + 第三方的反应）
- `project.yml` —— XcodeGen 配置（避免手写 pbxproj）
- `signing/export-unsigned-ipa.yml` —— 无 Mac 时用 GitHub Actions 出未签名 ipa（需复制到仓库根 `.github/workflows/`）

## 装机（有 Mac）

```bash
brew install xcodegen
xcodegen generate --spec project.yml
open DongtuCam.xcodeproj
```

Xcode 里选免费 Apple ID（Signing & Capabilities → 自动勾选 Team），连 iPhone 直接 Run。

## 装机（只有 Windows）

见根目录流程说明：推 GitHub → Actions 手动触发出 ipa → Sideloadly + 免费 Apple ID 侧载。

## 待真机验收

1. 相册是否显示「实况」标、长按文字全程在
2. 抖音是否给第三方写入的实况打 ⚙动图角标（最大不确定性）
3. 3:4 是否被机型支持（不支持自动回退默认比例）
4. 5 秒是否被平台完整接受
