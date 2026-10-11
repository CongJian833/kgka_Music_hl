# Android TV 遥控器适配（系统性）

> 目标：按 Android TV 规范，让全 App 的每个可交互控件都能被遥控器（D-pad）聚焦、
> 有明显焦点高亮、确定键可触发、弹窗可导航。本轮已实机（Philips 8H94A / Android 5.1.1 /
> armeabi-v7a / 1920×1080）验证通过。

## 一、根因

实测（注入 `KEYCODE_DPAD_*` + 焦点链路日志）发现三类问题：

1. **每个卡片有两个焦点节点**：现有代码普遍用 `TvFocusTarget(InkWell(...))`，
   而 `InkWell` 自带一个 focus 节点 → 同一张卡出现"外层环 + 内层 InkWell"两个落点，
   方向键要按两下才移动，感觉"很乱"。
2. **大量控件根本不可聚焦**：用 `GestureDetector` 自绘的卡片/封面、`ChoiceChip`、
   底部导航项、车机顶部标签、弹窗内容等没有焦点落点。
3. **弹窗/底部弹窗没有焦点作用域**：进入后确定键无处落，退不出也点不动。

## 二、改动清单

### 1. `lib/ui/widgets/tv_focus.dart`（核心）
- `TvFocusTarget` 新增 `descendantsAreFocusable`（默认 **false**）：默认只保留**单一焦点节点**，
  消除"一张卡两个落点"。子树里确有需要独立聚焦的子控件（如歌曲行里的点赞/更多）时显式传 `true`。

### 2. `lib/main.dart`
- 全局包一层 `FocusTraversalGroup(policy: WidgetOrderTraversalPolicy())`：
  所有页面统一按"上→下、左→右"的**几何就近**顺序移动焦点。
- `TvFocusMode.debugLogFocus` 正式发版置 **false**。

### 3. `lib/ui/widgets/tv_controls.dart`（新增）
- 遥控器友好的基础控件：`TvIconButton` / `TvTextButton` / `TvChipButton` / `TvTapArea`，
  以及竖向导航 `TvNavRail`。均保证"单焦点 + 明显高亮 + 确定键触发 + 保留触摸点击"。

### 4. `lib/ui/pages/app_shell.dart`
- 车机顶部导航：搜索胶囊 → `TvTapArea`；标签 → `TvChipButton`；设置 → `TvIconButton`。
- 底部导航 `BottomNavigationBar` → `TvBottomNavBar`；宽屏侧栏 `NavigationRail` → `TvNavRail`。

### 5. `lib/ui/widgets/app_theme.dart`（覆盖面关键）
- 主题层给 **所有** `IconButton` / `TextButton` 加"聚焦描边"（`WidgetState.focused` → `side`），
  并设置全局 `focusColor/hoverColor/highlightColor`。
  → 页面里没被逐一改造的原生 Material 控件也从此有清晰的焦点反馈。

### 6. 弹窗 / 底部弹窗
- `song_action_sheets.dart`（车机侧滑 + 底部弹窗两种形态）、
  `car_left_player_panel.dart`、`mini_player.dart` 的队列弹窗都包了 `TvFocusScope`（进入即聚焦首个可选项）；
  网格操作项改用 `TvTapArea`。

### 7. 其它
- 左侧播放面板专辑封面（进入播放器的入口）→ `TvTapArea`。
- 首页歌曲行 `_HomeSongRow` → `TvFocusTarget`（保留子按钮焦点），点赞/更多 → `TvIconButton`。

### 8. 【关键修复】左右方向键被"切歌"抢占
- `lib/ui/pages/app_shell.dart` 的 `AppShortcutScope` 原本**无条件**把
  `arrowLeft/arrowRight` 绑成"上一首/下一首"（桌面端快捷键），在 TV / 车机上它的
  优先级高于焦点遍历 → 遥控器左右键只会切歌、控件焦点无法左右移动。
- 改为**仅在非 TV（桌面端）**绑定左右键切歌；TV 上的上一首/下一首交给遥控器**媒体键**
  （`TvNavigationScope` 已处理 `mediaTrackNext/Previous`）。
- 实机验证：车机模式下连续按左右键，正在播放歌曲保持不变、焦点正常移动。

### 9. 【关键修复】左侧车机播放面板无法左右键聚焦（跨 FocusScope）
- **根因**：车机布局中，左侧 `CarLeftPlayerPanel` 在嵌套 `Navigator` **之外**，
  而内容是 `Navigator` 内的一条路由 —— 二者处于**不同的 FocusScope**。
  Flutter 的方向键遍历只在 `primaryFocus.nearestScope.traversalDescendants` 内查找
  （见 `flutter/src/widgets/focus_traversal.dart` `_moveFocus`），因此内容区焦点
  **永远进不去左侧面板**；这也是"焦点偶尔消失、跳来跳去"的来源。
- **修复**：在车机布局外层加一层 `_CarFocusBridge`（`Focus.onKeyEvent`，它比根部默认
  方向键 Shortcuts 更靠近焦点，能先拿到按键）：
  * 内容区按左且**左侧已无邻居** → 焦点交给左侧面板首个可聚焦项；
  * 左侧面板按右 → 焦点回到内容区上次聚焦的位置；
  * 其余情况一律 `ignored`，交还框架默认几何遍历。
- 桥接内所有逻辑都包了 `try/catch`：任何异常只会导致"不桥接"，**不会吞键、不影响启动**。

## 三、实机验证

- 注入 `KEYCODE_DPAD_UP/DOWN/LEFT/RIGHT`，`[TV_FOCUS_NODE]` 日志显示**每次按键焦点都移动**，
  路径覆盖：顶部标签 / 设置按钮 / 更新横幅关闭 / 首页功能卡 / 统计卡 …
- 截图确认焦点环清晰可见（卡片蓝色描边、IconButton 主题描边）。
- `flutter analyze --no-pub lib` 全绿。

## 四、构建 / 签名（本机）

```
# 环境
$env:PATH = 'E:\workspace-music\jdk17-tmp\jdk-17.0.20.1+1\bin;E:\flutter-sdk\bin;' + $env:PATH
$env:JAVA_HOME = 'E:\workspace-music\jdk17-tmp\jdk-17.0.20.1+1'
$env:ANDROID_HOME = 'E:\Android_SDK'; $env:ANDROID_SDK_ROOT = 'E:\Android_SDK'

flutter build apk --release --target-platform android-arm,android-arm64
```

⚠️ **签名**：本机 `flutter build` 用的是 `C:\Users\Public\Loomy\e7d3e769f3f5\opencode\.android\debug.keystore`，
与设备上已装 App 的签名（`C:\Users\Administrator\.android\debug.keystore`，SHA-256 `50abdfed…`）**不一致**，
覆盖安装会报 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`。安装到该设备前需用后者重新签名：

```
<build-tools>\zipalign -f -p 4 app-release.apk aligned.apk
<build-tools>\apksigner sign --ks C:\Users\Administrator\.android\debug.keystore \
  --ks-pass pass:android --ks-key-alias androiddebugkey --key-pass pass:android \
  --out ka-music-tv-release.apk aligned.apk
adb install -r ka-music-tv-release.apk
```

> 正式对外发布应使用项目的正式 keystore（`buildKey.keystore` + `android/key.properties`），
> 本轮的重新签名只是为了在测试设备上覆盖安装。

## 五、产物

| 文件 | 说明 |
| --- | --- |
| `dist/ka-music-tv-release.apk` | 本轮 TV 适配版（arm+arm64，已按测试机签名） |
| `dist/tv_shot1.png` / `f1.png` / `r1.png` | 实机焦点效果截图 |
