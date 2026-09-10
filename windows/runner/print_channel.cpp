#include "print_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <winspool.h>

#include <algorithm>
#include <cstring>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "fpdfview.h"

// ---------------------------------------------------------------------------
// pdfium 动态加载（DLL 与 exe 同目录，工作目录不可依赖）
// ---------------------------------------------------------------------------
namespace {

using PrintChannel = flutter::MethodChannel<flutter::EncodableValue>;
PrintChannel* g_channel = nullptr;
HWND g_hostWnd = nullptr;

typedef void (*PFN_InitLibrary)(FPDF_LIBRARY_CONFIG*);
typedef void (*PFN_FinalizeLibrary)();
typedef FPDF_DOCUMENT (*PFN_LoadDocument)(FPDF_STRING, FPDF_BYTESTRING);
typedef int (*PFN_GetPageCount)(FPDF_DOCUMENT);
typedef FPDF_PAGE (*PFN_LoadPage)(FPDF_DOCUMENT, int);
typedef void (*PFN_GetPageSizeByIndex)(FPDF_DOCUMENT, int, double*, double*);
typedef void (*PFN_RenderPage)(HDC, FPDF_PAGE, int, int, int, int, int, int);
typedef void (*PFN_ClosePage)(FPDF_PAGE);
typedef void (*PFN_CloseDocument)(FPDF_DOCUMENT);

PFN_InitLibrary p_Init;
PFN_FinalizeLibrary p_Finalize;
PFN_LoadDocument p_Load;
PFN_GetPageCount p_PageCount;
PFN_LoadPage p_LoadPage;
PFN_GetPageSizeByIndex p_PageSize;
PFN_RenderPage p_Render;
PFN_ClosePage p_ClosePage;
PFN_CloseDocument p_CloseDoc;

bool g_pdfiumTried = false;
bool g_pdfiumOk = false;

bool LoadPdfium() {
  if (g_pdfiumTried) return g_pdfiumOk;
  g_pdfiumTried = true;
  wchar_t exePath[MAX_PATH];
  GetModuleFileNameW(nullptr, exePath, MAX_PATH);
  std::wstring dir(exePath);
  size_t pos = dir.find_last_of(L'\\');
  if (pos != std::wstring::npos) dir = dir.substr(0, pos + 1);
  dir += L"pdfium.dll";
  HMODULE h = LoadLibraryW(dir.c_str());
  if (!h) return false;
  p_Init = (PFN_InitLibrary)GetProcAddress(h, "FPDF_InitLibrary");
  p_Finalize = (PFN_FinalizeLibrary)GetProcAddress(h, "FPDF_FinalizeLibrary");
  p_Load = (PFN_LoadDocument)GetProcAddress(h, "FPDF_LoadDocument");
  p_PageCount = (PFN_GetPageCount)GetProcAddress(h, "FPDF_GetPageCount");
  p_LoadPage = (PFN_LoadPage)GetProcAddress(h, "FPDF_LoadPage");
  p_PageSize = (PFN_GetPageSizeByIndex)GetProcAddress(h, "FPDF_GetPageSizeByIndex");
  p_Render = (PFN_RenderPage)GetProcAddress(h, "FPDF_RenderPage");
  p_ClosePage = (PFN_ClosePage)GetProcAddress(h, "FPDF_ClosePage");
  p_CloseDoc = (PFN_CloseDocument)GetProcAddress(h, "FPDF_CloseDocument");
  if (!p_Init || !p_Load || !p_PageCount || !p_LoadPage || !p_Render) return false;
  p_Init(nullptr);
  g_pdfiumOk = true;
  return true;
}

// ---------------------------------------------------------------------------
// 打印工具函数（与 tools/printspike 同源，此处为产品实现）
// ---------------------------------------------------------------------------

std::wstring GetPrinterPortName(const std::wstring& printer) {
  DWORD needed = 0, count = 0;
  EnumPrintersW(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, nullptr, 2, nullptr, 0,
                &needed, &count);
  std::vector<BYTE> buf(needed);
  if (!EnumPrintersW(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, nullptr, 2, buf.data(),
                     needed, &needed, &count))
    return L"";
  auto* pi = reinterpret_cast<PRINTER_INFO_2W*>(buf.data());
  for (DWORD i = 0; i < count; i++)
    if (_wcsicmp(pi[i].pPrinterName, printer.c_str()) == 0 && pi[i].pPortName)
      return pi[i].pPortName;
  return L"";
}

// DocumentProperties 会把驱动私有数据写在 DEVMODE 之后（dmDriverExtra），
// 必须按驱动声明的总大小堆分配，栈上定长结构必崩 0xC0000409。
DEVMODEW* AllocDevMode(const std::wstring& printer, std::vector<BYTE>& store) {
  LONG sz = DocumentPropertiesW(nullptr, nullptr, (LPWSTR)printer.c_str(), nullptr, nullptr,
                                DM_OUT_BUFFER);
  if (sz < (LONG)sizeof(DEVMODEW)) sz = sizeof(DEVMODEW);
  store.assign((size_t)sz, 0);
  auto* p = reinterpret_cast<DEVMODEW*>(store.data());
  p->dmSize = sizeof(DEVMODEW);
  return p;
}

// "1-3,5" → 0-based；空 = 全部
std::vector<int> ParsePages(const std::wstring& spec, int total) {
  std::vector<int> out;
  if (spec.empty()) {
    for (int i = 0; i < total; i++) out.push_back(i);
    return out;
  }
  wchar_t buf[256];
  wcsncpy_s(buf, spec.c_str(), 255);
  buf[255] = 0;
  wchar_t* tok = wcstok(buf, L",");
  while (tok) {
    int a = 0, b = 0;
    if (swscanf(tok, L"%d-%d", &a, &b) == 2) {
      for (int i = a; i <= b && i <= total; i++)
        if (i >= 1) out.push_back(i - 1);
    } else if (swscanf(tok, L"%d", &a) == 1) {
      if (a >= 1 && a <= total) out.push_back(a - 1);
    }
    tok = wcstok(nullptr, L",");
  }
  return out;
}

std::string WideToUtf8(const std::wstring& w) {
  if (w.empty()) return "";
  int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, nullptr, 0, nullptr, nullptr);
  std::string s(n, 0);
  WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, s.data(), n, nullptr, nullptr);
  s.resize(strlen(s.c_str()));
  return s;
}

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return L"";
  int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  std::wstring w(n, 0);
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, w.data(), n);
  w.resize(wcslen(w.c_str()));
  return w;
}

std::string GetStrArg(const flutter::EncodableMap& m, const char* key) {
  auto it = m.find(flutter::EncodableValue(key));
  if (it != m.end()) {
    if (auto* s = std::get_if<std::string>(&it->second)) return *s;
  }
  return "";
}

int GetIntArg(const flutter::EncodableMap& m, const char* key, int dflt) {
  auto it = m.find(flutter::EncodableValue(key));
  if (it != m.end()) {
    if (auto* v = std::get_if<int32_t>(&it->second)) return *v;
    if (auto* v = std::get_if<int64_t>(&it->second)) return (int)*v;
  }
  return dflt;
}

bool GetBoolArg(const flutter::EncodableMap& m, const char* key, bool dflt) {
  auto it = m.find(flutter::EncodableValue(key));
  if (it != m.end()) {
    if (auto* v = std::get_if<bool>(&it->second)) return *v;
  }
  return dflt;
}

// 核心：把 PDF 打到打印机。返回空串成功，否则错误信息。
std::string DoPrintPdf(const std::wstring& pdfPath, const std::wstring& printer, int copies,
                       const std::wstring& pagesSpec, const std::wstring& duplex, bool color,
                       int paperCode, bool raw100) {
  if (!LoadPdfium()) return "pdfium.dll \u52a0\u8f7d\u5931\u8d25";

  std::vector<BYTE> dmStore;
  DEVMODEW* dm = AllocDevMode(printer, dmStore);
  if (DocumentPropertiesW(nullptr, nullptr, (LPWSTR)printer.c_str(), dm, nullptr,
                          DM_OUT_BUFFER) != IDOK)
    return "DocumentProperties \u5931\u8d25";

  dm->dmCopies = (short)std::max(1, std::min(copies, 99));
  dm->dmFields |= DM_COPIES;
  if (color) {
    // 只有驱动支持彩色才设，避免 merge 被清零后语义混乱
    dm->dmColor = DMCOLOR_COLOR;
    dm->dmFields |= DM_COLOR;
  } else {
    dm->dmColor = DMCOLOR_MONOCHROME;
    dm->dmFields |= DM_COLOR;
  }
  if (duplex == L"long") {
    dm->dmDuplex = DMDUP_VERTICAL;
    dm->dmFields |= DM_DUPLEX;
  } else if (duplex == L"short") {
    dm->dmDuplex = DMDUP_HORIZONTAL;
    dm->dmFields |= DM_DUPLEX;
  }
  if (paperCode > 0) {
    dm->dmPaperSize = (WORD)paperCode;
    dm->dmFields |= DM_PAPERSIZE;
  }

  // 取 merge 结果前先把 dm 内容拷出（两者不能指向同一 scratch）
  DEVMODEW dmIn = *dm;
  std::vector<BYTE> mergeBuf(dmStore.size(), 0);
  auto* out = reinterpret_cast<DEVMODEW*>(mergeBuf.data());
  out->dmSize = sizeof(DEVMODEW);
  if (DocumentPropertiesW(nullptr, nullptr, (LPWSTR)printer.c_str(), out, &dmIn,
                          DM_IN_BUFFER | DM_OUT_BUFFER) != IDOK)
    return "DocumentProperties \u5408\u5e76\u5931\u8d25";

  HDC hdc = CreateDCW(L"WINSPOOL", printer.c_str(), nullptr, out);
  if (!hdc) return "CreateDC \u5931\u8d25\uff08\u6253\u5370\u673a\u79bb\u7ebf\uff1f\uff09";

  int dpiX = GetDeviceCaps(hdc, LOGPIXELSX);
  int dpiY = GetDeviceCaps(hdc, LOGPIXELSY);
  int physW = GetDeviceCaps(hdc, PHYSICALWIDTH);
  int physH = GetDeviceCaps(hdc, PHYSICALHEIGHT);
  int offX = GetDeviceCaps(hdc, PHYSICALOFFSETX);
  int offY = GetDeviceCaps(hdc, PHYSICALOFFSETY);

  DOCINFOW di{};
  di.cbSize = sizeof(di);
  di.lpszDocName = L"CrossLink";
  if (StartDocW(hdc, &di) <= 0) {
    DeleteDC(hdc);
    return "StartDoc \u5931\u8d25";
  }

  std::string utf8 = WideToUtf8(pdfPath);
  FPDF_DOCUMENT doc = p_Load(utf8.c_str(), nullptr);
  if (!doc) {
    AbortDoc(hdc);
    DeleteDC(hdc);
    return "PDF \u6253\u5f00\u5931\u8d25";
  }
  int total = p_PageCount(doc);
  std::vector<int> pages = ParsePages(pagesSpec, total);

  // 正式落位策略 raw100：客户端驱动已排版，1:1 铺到纸张原点，不缩放不居中。
  // 仅当页面大于纸张（如手工送大稿）才整体缩到可打印区。
  for (int idx : pages) {
    FPDF_PAGE page = p_LoadPage(doc, idx);
    if (!page) continue;
    double wpt = 0, hpt = 0;
    p_PageSize(doc, idx, &wpt, &hpt);
    double wpix = wpt * dpiX / 72.0, hpix = hpt * dpiY / 72.0;
    int x = 0, y = 0, w = (int)wpix, h = (int)hpix;
    if (!raw100 || wpix > physW || hpix > physH) {
      double areaW = physW - 2.0 * offX, areaH = physH - 2.0 * offY;
      double scale = std::min(areaW / wpix, areaH / hpix);
      if (scale > 1.0) scale = 1.0;
      w = (int)(wpix * scale);
      h = (int)(hpix * scale);
      x = offX + (int)((areaW - w) / 2);
      y = offY + (int)((areaH - h) / 2);
    }
    StartPage(hdc);
    p_Render(hdc, page, x, y, w, h, 0, FPDF_ANNOT | FPDF_PRINTING);
    EndPage(hdc);
    p_ClosePage(page);
  }
  p_CloseDoc(doc);
  int rc = EndDoc(hdc);
  DeleteDC(hdc);
  return rc > 0 ? "" : "EndDoc \u5931\u8d25";
}

// ---------------------------------------------------------------------------
// 通道方法
// ---------------------------------------------------------------------------
void HandleListPrinters(
    const flutter::EncodableValue* args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  DWORD needed = 0, count = 0;
  EnumPrintersW(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, nullptr, 2, nullptr, 0, &needed,
                &count);
  std::vector<BYTE> buf(needed);
  if (!EnumPrintersW(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, nullptr, 2, buf.data(),
                     needed, &needed, &count)) {
    result->Error("enum", "EnumPrinters \u5931\u8d25");
    return;
  }
  auto* pi = reinterpret_cast<PRINTER_INFO_2W*>(buf.data());
  flutter::EncodableList list;
  for (DWORD i = 0; i < count; i++) {
    flutter::EncodableMap m;
    m[flutter::EncodableValue("name")] = flutter::EncodableValue(WideToUtf8(pi[i].pPrinterName));
    m[flutter::EncodableValue("port")] =
        flutter::EncodableValue(WideToUtf8(pi[i].pPortName ? pi[i].pPortName : L""));
    m[flutter::EncodableValue("isDefault")] =
        flutter::EncodableValue((pi[i].Attributes & PRINTER_ATTRIBUTE_DEFAULT) != 0);
    m[flutter::EncodableValue("network")] =
        flutter::EncodableValue((pi[i].Attributes & PRINTER_ATTRIBUTE_NETWORK) != 0);
    m[flutter::EncodableValue("status")] = flutter::EncodableValue((int32_t)pi[i].Status);
    list.push_back(flutter::EncodableValue(std::move(m)));
  }
  result->Success(flutter::EncodableValue(std::move(list)));
}

// 打印机是否离线（含 WORK_OFFLINE 属性与离线/不可用状态位）。
// 用于能力查询前的预检：对离线网络打印机调 DeviceCapabilitiesW
// 会触发驱动去连接设备，Windows 弹"等待连接"对话框并长时间阻塞。
static bool IsPrinterOffline(const std::wstring& name) {
  HANDLE h = nullptr;
  if (!OpenPrinterW((LPWSTR)name.c_str(), &h, nullptr)) return true;
  DWORD needed = 0;
  GetPrinterW(h, 2, nullptr, 0, &needed);
  std::vector<BYTE> buf(needed);
  bool offline = false;
  if (GetPrinterW(h, 2, buf.data(), needed, &needed)) {
    auto* pi = reinterpret_cast<PRINTER_INFO_2W*>(buf.data());
    if (pi->Attributes & PRINTER_ATTRIBUTE_WORK_OFFLINE) offline = true;
    if (pi->Status & (PRINTER_STATUS_OFFLINE | PRINTER_STATUS_NOT_AVAILABLE |
                      PRINTER_STATUS_ERROR))
      offline = true;
  }
  ClosePrinter(h);
  return offline;
}

void HandlePrinterCaps(
    const flutter::EncodableValue* args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  auto* map = std::get_if<flutter::EncodableMap>(args);
  if (!map) {
    result->Error("args", "\u7f3a\u5c11 name");
    return;
  }
  std::wstring name = Utf8ToWide(GetStrArg(*map, "name"));
  // 离线预检：直接返回默认能力，避免驱动连接弹窗与阻塞
  if (IsPrinterOffline(name)) {
    flutter::EncodableMap out;
    out[flutter::EncodableValue("duplex")] = flutter::EncodableValue(false);
    out[flutter::EncodableValue("color")] = flutter::EncodableValue(false);
    out[flutter::EncodableValue("maxCopies")] =
        flutter::EncodableValue((int32_t)1);
    out[flutter::EncodableValue("papers")] =
        flutter::EncodableValue(flutter::EncodableList());
    result->Success(flutter::EncodableValue(std::move(out)));
    return;
  }
  std::wstring port = GetPrinterPortName(name);
  flutter::EncodableMap out;
  out[flutter::EncodableValue("duplex")] =
      flutter::EncodableValue(DeviceCapabilitiesW(name.c_str(), port.c_str(), DC_DUPLEX, nullptr,
                                                  nullptr) == 1);
  out[flutter::EncodableValue("color")] =
      flutter::EncodableValue(DeviceCapabilitiesW(name.c_str(), port.c_str(), DC_COLORDEVICE,
                                                  nullptr, nullptr) == 1);
  out[flutter::EncodableValue("maxCopies")] = flutter::EncodableValue(
      (int32_t)DeviceCapabilitiesW(name.c_str(), port.c_str(), DC_COPIES, nullptr, nullptr));
  // 纸张表用 EnumForms（稳定）；DC_PAPERNAMES 在部分厂商驱动上会崩
  out[flutter::EncodableValue("papers")] = flutter::EncodableValue(flutter::EncodableList());
  HANDLE hPrinter = nullptr;
  if (OpenPrinterW((LPWSTR)name.c_str(), &hPrinter, nullptr)) {
    DWORD needed = 0, returned = 0;
    EnumForms(hPrinter, 1, nullptr, 0, &needed, &returned);
    std::vector<BYTE> buf(needed > 0 ? needed : 0);
    if (needed > 0 && EnumForms(hPrinter, 1, buf.data(), needed, &needed, &returned)) {
      auto* forms = reinterpret_cast<FORM_INFO_1W*>(buf.data());
      flutter::EncodableList papers;
      for (DWORD i = 0; i < returned; i++) {
        if (!(forms[i].Flags & FORM_USER)) continue;  // 只列驱动内置
        flutter::EncodableMap p;
        p[flutter::EncodableValue("name")] = flutter::EncodableValue(WideToUtf8(forms[i].pName));
        p[flutter::EncodableValue("wmm")] =
            flutter::EncodableValue((int32_t)(forms[i].Size.cx / 10));
        p[flutter::EncodableValue("hmm")] =
            flutter::EncodableValue((int32_t)(forms[i].Size.cy / 10));
        papers.push_back(flutter::EncodableValue(std::move(p)));
      }
      out[flutter::EncodableValue("papers")] = flutter::EncodableValue(std::move(papers));
    }
    ClosePrinter(hPrinter);
  }
  result->Success(flutter::EncodableValue(std::move(out)));
}

void HandlePrinterStatus(
    const flutter::EncodableValue* args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  auto* map = std::get_if<flutter::EncodableMap>(args);
  if (!map) {
    result->Error("args", "\u7f3a\u5c11 name");
    return;
  }
  std::wstring name = Utf8ToWide(GetStrArg(*map, "name"));
  HANDLE hPrinter = nullptr;
  if (!OpenPrinterW((LPWSTR)name.c_str(), &hPrinter, nullptr)) {
    flutter::EncodableMap out;
    out[flutter::EncodableValue("status")] = flutter::EncodableValue((int32_t)-1);
    result->Success(flutter::EncodableValue(std::move(out)));
    return;
  }
  DWORD needed = 0;
  GetPrinterW(hPrinter, 2, nullptr, 0, &needed);
  std::vector<BYTE> buf(needed);
  int32_t status = 0;
  if (GetPrinterW(hPrinter, 2, buf.data(), needed, &needed)) {
    auto* pi = reinterpret_cast<PRINTER_INFO_2W*>(buf.data());
    status = (int32_t)pi->Status;
    if (pi->Attributes & PRINTER_ATTRIBUTE_WORK_OFFLINE) status |= 0x10000000;
  }
  ClosePrinter(hPrinter);
  flutter::EncodableMap out;
  out[flutter::EncodableValue("status")] = flutter::EncodableValue(status);
  result->Success(flutter::EncodableValue(std::move(out)));
}

void HandlePrintPdf(
    const flutter::EncodableValue* args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  auto* map = std::get_if<flutter::EncodableMap>(args);
  if (!map) {
    result->Error("args", "\u53c2\u6570\u9519\u8bef");
    return;
  }
  std::string pathUtf8 = GetStrArg(*map, "path");
  std::string printerUtf8 = GetStrArg(*map, "printer");
  int copies = GetIntArg(*map, "copies", 1);
  std::wstring pages = Utf8ToWide(GetStrArg(*map, "pages"));
  std::wstring duplex = Utf8ToWide(GetStrArg(*map, "duplex"));
  bool color = GetBoolArg(*map, "color", false);
  int paperCode = GetIntArg(*map, "paperCode", 0);
  bool raw100 = GetBoolArg(*map, "raw100", true);
  int jobId = GetIntArg(*map, "jobId", 0);

  HWND host = g_hostWnd;
  std::thread([pathUtf8, printerUtf8, copies, pages, duplex, color, paperCode, raw100, jobId,
               host]() {
    std::wstring wpath = Utf8ToWide(pathUtf8);
    std::wstring wprinter = Utf8ToWide(printerUtf8);
    std::string err =
        DoPrintPdf(wpath, wprinter, copies, pages, duplex, color, paperCode, raw100);
    DeleteFileA(pathUtf8.c_str());  // 无论成败都清理临时 PDF（成功=已出纸，失败=不再重试）
    if (host) {
      PostMessageW(host, WM_CL_PRINT_DONE, (WPARAM)jobId, (LPARAM)new std::string(err));
    }
  }).detach();

  flutter::EncodableMap out;
  out[flutter::EncodableValue("accepted")] = flutter::EncodableValue(true);
  result->Success(flutter::EncodableValue(std::move(out)));
}

}  // namespace

void RegisterPrintChannel(flutter::FlutterEngine* engine) {
  static PrintChannel channel(engine->messenger(), "com.crosslink.crosslink/print",
                              &flutter::StandardMethodCodec::GetInstance());
  g_channel = &channel;
  channel.SetMethodCallHandler(
      [](const auto& call, auto result) {
        const std::string& m = call.method_name();
        if (m == "listPrinters") {
          HandleListPrinters(call.arguments(), std::move(result));
        } else if (m == "printerCaps") {
          HandlePrinterCaps(call.arguments(), std::move(result));
        } else if (m == "printerStatus") {
          HandlePrinterStatus(call.arguments(), std::move(result));
        } else if (m == "printPdf") {
          HandlePrintPdf(call.arguments(), std::move(result));
        } else {
          result->NotImplemented();
        }
      });
}

void SetPrintHostWindow(HWND hwnd) { g_hostWnd = hwnd; }

bool HandlePrintDoneMessage(WPARAM wParam, LPARAM lParam) {
  std::unique_ptr<std::string> err(reinterpret_cast<std::string*>(lParam));
  if (g_channel) {
    flutter::EncodableMap ev;
    ev[flutter::EncodableValue("event")] = flutter::EncodableValue("jobDone");
    ev[flutter::EncodableValue("jobId")] = flutter::EncodableValue((int)(INT_PTR)wParam);
    ev[flutter::EncodableValue("error")] = flutter::EncodableValue(*err);
    g_channel->InvokeMethod("onPrintEvent",
                            std::make_unique<flutter::EncodableValue>(std::move(ev)));
  }
  return true;
}
