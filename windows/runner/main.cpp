#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdio>
#include <fstream>
#include <iostream>
#include <string>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Single instance: only one process is allowed at a time.
  // On a second launch, focus the existing window and then exit this process.
  // (Mutex name has no "Global\" prefix, scoped to the current user session.)
  HANDLE single_instance_mutex =
      CreateMutexW(nullptr, TRUE, L"KA_Music_Single_Instance");
  if (single_instance_mutex != nullptr &&
      GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing = FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr);
    if (existing != nullptr) {
      ::ShowWindow(existing, SW_RESTORE);
      ::SetForegroundWindow(existing);
    }
    if (single_instance_mutex != nullptr) {
      CloseHandle(single_instance_mutex);
    }
    return 0;
  }
  // The single_instance_mutex remains open until the process exits,
  // keeping the single-instance lock alive.

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // 无控制台（实际安装 / 双击运行）时，将 stderr/stdout 重定向到日志文件，
  // 以便捕获 just_audio_windows 等原生插件通过 std::cerr 打印的信息
  // （如 "[just_audio_windows] Item error: ..."），用于诊断播放卡死。
  static std::ofstream stderr_log_, stdout_log_;
  if (!::GetConsoleWindow()) {
    wchar_t tmp_path[MAX_PATH]{};
    ::GetTempPathW(MAX_PATH, tmp_path);
    const std::wstring dir(tmp_path);
    stderr_log_.open(dir + L"ka_music_stderr.log", std::ios::app);
    stdout_log_.open(dir + L"ka_music_stdout.log", std::ios::app);
    std::cerr.rdbuf(stderr_log_.rdbuf());
    std::cout.rdbuf(stdout_log_.rdbuf());
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"KA Music", origin, size)) {
    return EXIT_FAILURE;
  }
  // 显示主窗口。模板默认依赖 Flutter 首帧回调（SetNextFrameCallback -> Show）来显示，
  // 但首帧回调存在未触发的时序风险，导致启动后窗口不可见。
  // 这里在创建窗口后主动显示一次，确保应用启动即有可见主界面。
  window.Show();
  // Close behavior is delegated to the Dart layer:
  // window_manager intercepts the close event and decides whether to
  // hide to the system tray or truly exit.
  window.SetQuitOnClose(false);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
