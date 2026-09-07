#ifndef PRINT_CHANNEL_H_
#define PRINT_CHANNEL_H_

#include <flutter/flutter_engine.h>
#include <windows.h>

// 打印完成消息（工作线程 PostMessage → 平台线程 MessageHandler）
#define WM_CL_PRINT_DONE (WM_APP + 0x51)

// 注册 com.crosslink.crosslink/print 通道：
//   listPrinters / printerCaps / printerStatus / printPdf（异步，完成后
//   经 onPrintEvent 事件回 {jobId, error}）
void RegisterPrintChannel(flutter::FlutterEngine* engine);

// 主窗口句柄（工作线程回投消息用）
void SetPrintHostWindow(HWND hwnd);

// 处理 WM_CL_PRINT_DONE：wParam=jobId，lParam=std::string*（错误串，空=成功）
bool HandlePrintDoneMessage(WPARAM wParam, LPARAM lParam);

#endif  // PRINT_CHANNEL_H_
