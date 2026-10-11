#include "flutter_window.h"

#include <optional>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Native -> Dart channel: reports window sizing/maximize/fullscreen changes
  // so the custom title bar's maximize/restore button can refresh instantly
  // without polling. The Dart side uses its authoritative
  // windowManager.isMaximized() to decide the icon.
  window_state_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "ka_music/window_state",
          &flutter::StandardMethodCodec::GetInstance());

  // 注：此前曾尝试在此为 channel 注册 Dart->Native 的 'quit' 处理器以实现"优雅退出"
  // （PostQuitMessage(0) 结束消息循环）。实测该优雅退出方案不生效（进程悬挂 + 仍崩溃 +
  // WerFault 自重启），已回退移除；本 channel 目前仅用于 Native->Dart 的状态上报
  // (InvokeMethod("windowStateChanged"))。

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Fire this before plugins get a chance to intercept WM_SIZE, so the custom
  // title bar always learns about maximize/restore/fullscreen transitions even
  // when another handler consumes the message. Delegate the actual icon
  // decision to the Dart layer (windowManager.isMaximized()), which also
  // covers frameless fullscreen where ::IsZoomed() may report false.
  if (message == WM_SIZE && window_state_channel_) {
    window_state_channel_->InvokeMethod("windowStateChanged", nullptr);
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
