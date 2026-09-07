// printspike.cpp — CrossLink 打印引擎技术验证（2.3.0 前置 spike）
//
// 用法：
//   printspike printers
//   printspike caps "<printer>"
//   printspike render "<file.pdf>" "<out_prefix>" [--pages 1-3,5]
//   printspike print "<file.pdf>" "<printer>" [--pages 1-3,5] [--copies N]
//              [--duplex long|short] [--color|--mono] [--paper A4|A3|51]
//
// 设计：pdfium.dll 动态加载（免导入库，后期 Flutter 集成同样姿势）；
// GDI 打印：DocumentProperties 取 DEVMODE → 改五项 → CreateDC → FPDF_RenderPageDC。
#include <windows.h>
#include <winspool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <string>
#include <vector>

// ---------- pdfium 动态加载 ----------
typedef void* FPDF_HANDLE;
typedef struct { int version; void* allocator; void* suspend; void* resume; } FPDF_CONFIG;
typedef void   (__cdecl *PFN_InitLibrary)(FPDF_CONFIG*);
typedef void   (__cdecl *PFN_FinalizeLibrary)();
typedef FPDF_HANDLE (__cdecl *PFN_LoadDocument)(const char*, const char*);
typedef int    (__cdecl *PFN_GetPageCount)(FPDF_HANDLE);
typedef FPDF_HANDLE (__cdecl *PFN_LoadPage)(FPDF_HANDLE, int);
typedef void   (__cdecl *PFN_GetPageSizeByIndex)(FPDF_HANDLE, int, double*, double*);
typedef void   (__cdecl *PFN_RenderPage)(HDC, FPDF_HANDLE, int, int, int, int, int, int);
typedef void   (__cdecl *PFN_ClosePage)(FPDF_HANDLE);
typedef void   (__cdecl *PFN_CloseDocument)(FPDF_HANDLE);

static PFN_InitLibrary          fpdf_Init;
static PFN_FinalizeLibrary      fpdf_Finalize;
static PFN_LoadDocument         fpdf_Load;
static PFN_GetPageCount         fpdf_PageCount;
static PFN_LoadPage             fpdf_LoadPage;
static PFN_GetPageSizeByIndex   fpdf_PageSize;
static PFN_RenderPage           fpdf_Render;
static PFN_ClosePage            fpdf_ClosePage;
static PFN_CloseDocument        fpdf_CloseDoc;

static bool LoadPdfium(const wchar_t* dllPath) {
  HMODULE h = LoadLibraryW(dllPath);
  if (!h) { wprintf(L"[x] LoadLibrary pdfium.dll failed err=%lu\n", GetLastError()); return false; }
  fpdf_Init      = (PFN_InitLibrary)GetProcAddress(h, "FPDF_InitLibrary");
  fpdf_Finalize  = (PFN_FinalizeLibrary)GetProcAddress(h, "FPDF_FinalizeLibrary");
  fpdf_Load      = (PFN_LoadDocument)GetProcAddress(h, "FPDF_LoadDocument");
  fpdf_PageCount = (PFN_GetPageCount)GetProcAddress(h, "FPDF_GetPageCount");
  fpdf_LoadPage  = (PFN_LoadPage)GetProcAddress(h, "FPDF_LoadPage");
  fpdf_PageSize  = (PFN_GetPageSizeByIndex)GetProcAddress(h, "FPDF_GetPageSizeByIndex");
  fpdf_Render    = (PFN_RenderPage)GetProcAddress(h, "FPDF_RenderPage");
  fpdf_ClosePage = (PFN_ClosePage)GetProcAddress(h, "FPDF_ClosePage");
  fpdf_CloseDoc  = (PFN_CloseDocument)GetProcAddress(h, "FPDF_CloseDocument");
  if (!fpdf_Init || !fpdf_Load || !fpdf_PageCount || !fpdf_LoadPage || !fpdf_Render) {
    wprintf(L"[x] pdfium symbols missing: init=%p load=%p count=%p loadpage=%p render=%p\n",
            (void*)fpdf_Init, (void*)fpdf_Load, (void*)fpdf_PageCount,
            (void*)fpdf_LoadPage, (void*)fpdf_Render);
    return false;
  }
  fpdf_Init(NULL);
  return true;
}

// ---------- 工具函数 ----------
static int ArgInt(int argc, wchar_t** argv, const wchar_t* name, int dflt) {
  for (int i = 0; i < argc - 1; i++)
    if (_wcsicmp(argv[i], name) == 0) return _wtoi(argv[i + 1]);
  return dflt;
}
static bool ArgFlag(int argc, wchar_t** argv, const wchar_t* name) {
  for (int i = 0; i < argc; i++)
    if (_wcsicmp(argv[i], name) == 0) return true;
  return false;
}
static const wchar_t* ArgVal(int argc, wchar_t** argv, const wchar_t* name) {
  for (int i = 0; i < argc - 1; i++)
    if (_wcsicmp(argv[i], name) == 0) return argv[i + 1];
  return NULL;
}

// "1-3,5" → 0-based 页码列表；空 = 全部
static std::vector<int> ParsePages(const wchar_t* spec, int total) {
  std::vector<int> out;
  if (!spec || !*spec) { for (int i = 0; i < total; i++) out.push_back(i); return out; }
  wchar_t buf[256]; wcsncpy_s(buf, spec, 255); buf[255] = 0;
  wchar_t* tok = wcstok(buf, L",");
  while (tok) {
    int a = 0, b = 0;
    if (swscanf(tok, L"%d-%d", &a, &b) == 2) {
      for (int i = a; i <= b && i <= total; i++) if (i >= 1) out.push_back(i - 1);
    } else if (swscanf(tok, L"%d", &a) == 1) {
      if (a >= 1 && a <= total) out.push_back(a - 1);
    }
    tok = wcstok(NULL, L",");
  }
  return out;
}

// ---------- printers：枚举 ----------
static int DoPrinters() {
  DWORD needed = 0, count = 0;
  EnumPrintersW(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, NULL, 2, NULL, 0, &needed, &count);
  std::vector<BYTE> buf(needed);
  if (!EnumPrintersW(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, NULL, 2, buf.data(), needed, &needed, &count))
    { wprintf(L"[x] EnumPrinters failed\n"); return 1; }
  PRINTER_INFO_2W* pi = (PRINTER_INFO_2W*)buf.data();
  for (DWORD i = 0; i < count; i++) {
    wprintf(L"%ls%ls  Status=%lu  %ls\n",
            (pi[i].Attributes & PRINTER_ATTRIBUTE_DEFAULT) ? L"* " : L"  ",
            pi[i].pPrinterName, pi[i].Status, pi[i].pPortName ? pi[i].pPortName : L"");
  }
  return 0;
}

// ---------- caps：驱动能力 ----------
// DocumentProperties 会把驱动私有数据写在 DEVMODE 结构之后（dmDriverExtra），
// 必须按驱动声明的总大小堆分配，否则栈溢出（0xC0000409）
static DEVMODEW* DevModeBuf(std::vector<BYTE>& v, const wchar_t* printer) {
  LONG sz = DocumentPropertiesW(NULL, NULL, (LPWSTR)printer, NULL, NULL, DM_OUT_BUFFER);
  if (sz < (LONG)sizeof(DEVMODEW)) sz = sizeof(DEVMODEW);
  v.assign((size_t)sz, 0);
  DEVMODEW* p = (DEVMODEW*)v.data();
  p->dmSize = sizeof(DEVMODEW);
  return p;
}

// 查打印机端口名：DeviceCapabilities 必须带 pPort，否则部分驱动直接返回 0
static std::wstring GetPrinterPort(const wchar_t* printer) {
  DWORD needed = 0, count = 0;
  EnumPrintersW(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, NULL, 2, NULL, 0, &needed, &count);
  std::vector<BYTE> buf(needed);
  if (!EnumPrintersW(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, NULL, 2, buf.data(), needed, &needed, &count))
    return L"";
  PRINTER_INFO_2W* pi = (PRINTER_INFO_2W*)buf.data();
  for (DWORD i = 0; i < count; i++)
    if (_wcsicmp(pi[i].pPrinterName, printer) == 0 && pi[i].pPortName)
      return pi[i].pPortName;
  return L"";
}

static int DoCaps(const wchar_t* printer) {
  std::wstring portW = GetPrinterPort(printer);
  const wchar_t* port = portW.empty() ? NULL : portW.c_str();
  wprintf(L"port    : %ls\n", portW.empty() ? L"?" : portW.c_str());
  std::vector<BYTE> dmBuf;
  DEVMODEW* pDm = DevModeBuf(dmBuf, printer);
  if (DocumentPropertiesW(NULL, NULL, (LPWSTR)printer, pDm, NULL, DM_OUT_BUFFER) != IDOK) {
    wprintf(L"[x] DocumentProperties failed\n"); return 1;
  }
  DEVMODEW& dm = *pDm;
  wprintf(L"printer : %ls\n", printer);
  wprintf(L"copies  : driver max = %d\n",
          DeviceCapabilitiesW(printer, port, DC_COPIES, NULL, NULL));
  int duplex = DeviceCapabilitiesW(printer, port, DC_DUPLEX, NULL, NULL);
  wprintf(L"duplex  : %ls (current dmDuplex=%u)\n",
          duplex == 1 ? L"supports automatic duplex" : L"NO automatic duplex",
          dm.dmDuplex);
  wprintf(L"color   : current dmColor=%u (1=mono 2=color)\n", dm.dmColor);
  wprintf(L"paper   : current dmPaperSize=%u\n", dm.dmPaperSize);
  const int kCap = 128;
  std::vector<WORD> papers(kCap);
  int n = DeviceCapabilitiesW(printer, port, DC_PAPERS, (LPWSTR)papers.data(), &dm);
  DWORD e1 = GetLastError();
  int n2 = DeviceCapabilitiesW(printer, port, DC_PAPERS, (LPWSTR)papers.data(), NULL);
  DWORD e2 = GetLastError();
  wprintf(L"[dbg] DC_PAPERS with-dm=%d(err=%lu) no-dm=%d(err=%lu)\n", n, e1, n2, e2);
  if (n <= 0) n = n2;
  if (n > kCap) n = kCap;
  if (n > 0) {
    // 注意：DC_PAPERNAMES/DC_PAPERSIZE 在部分厂商驱动上不稳定（Canon 实测崩溃），
    // 正式实现改用 EnumFormsEx 取纸张表；spike 只报数量。
    wprintf(L"papers  : %d supported\n", n);
  }
  return 0;
}

// ---------- render：出 BMP 验证 pdfium ----------
static int DoRender(const wchar_t* pdf, const wchar_t* outPrefix, const wchar_t* pagesSpec) {
  int total = 0;
  {
    char utf8[MAX_PATH];
    WideCharToMultiByte(CP_UTF8, 0, pdf, -1, utf8, sizeof(utf8), NULL, NULL);
    FPDF_HANDLE doc = fpdf_Load(utf8, NULL);
    if (!doc) { wprintf(L"[x] load failed\n"); return 1; }
    total = fpdf_PageCount(doc);
    fpdf_CloseDoc(doc);
  }
  std::vector<int> pages = ParsePages(pagesSpec, total);
  int dpi = 150;
  for (int idx : pages) {
    char utf8[MAX_PATH];
    WideCharToMultiByte(CP_UTF8, 0, pdf, -1, utf8, sizeof(utf8), NULL, NULL);
    FPDF_HANDLE doc = fpdf_Load(utf8, NULL);
    FPDF_HANDLE page = fpdf_LoadPage(doc, idx);
    double wpt = 0, hpt = 0; fpdf_PageSize(doc, idx, &wpt, &hpt);
    int w = (int)(wpt * dpi / 72), h = (int)(hpt * dpi / 72);
    HDC screen = GetDC(NULL);
    HDC mem = CreateCompatibleDC(screen);
    HBITMAP bmp = CreateCompatibleBitmap(screen, w, h);
    HBITMAP oldBmp = (HBITMAP)SelectObject(mem, bmp);
    HBRUSH white = CreateSolidBrush(RGB(255,255,255));
    RECT rc = {0,0,w,h}; FillRect(mem, &rc, white); DeleteObject(white);
    fpdf_Render(mem, page, 0, 0, w, h, 0, 2|4);
    SelectObject(mem, oldBmp);
    wchar_t outPath[MAX_PATH];
    swprintf(outPath, MAX_PATH, L"%ls_p%d.bmp", outPrefix, idx + 1);
    // 保存 DDB → BMP via GetDIBits
    BITMAPFILEHEADER bfh = {}; BITMAPINFOHEADER bih = {};
    bih.biSize = sizeof(bih); bih.biWidth = w; bih.biHeight = -h;
    bih.biPlanes = 1; bih.biBitCount = 24; bih.biCompression = BI_RGB;
    DWORD stride = ((DWORD)w * 3 + 3) & ~3u;
    DWORD imgSize = stride * h;
    std::vector<BYTE> img(imgSize);
    BITMAPINFO bi = {}; bi.bmiHeader = bih;
    GetDIBits(mem, bmp, 0, h, img.data(), &bi, DIB_RGB_COLORS);
    bfh.bfType = 0x4D42; bfh.bfOffBits = sizeof(bfh) + sizeof(bih);
    bfh.bfSize = bfh.bfOffBits + imgSize;
    FILE* f = _wfopen(outPath, L"wb");
    if (f) { fwrite(&bfh, sizeof(bfh), 1, f); fwrite(&bih, sizeof(bih), 1, f);
             fwrite(img.data(), 1, imgSize, f); fclose(f); }
    DeleteObject(bmp); DeleteDC(mem); ReleaseDC(NULL, screen);
    wprintf(L"[i] wrote %ls (%dx%d)\n", outPath, w, h);
    fpdf_ClosePage(page); fpdf_CloseDoc(doc);
  }
  return 0;
}

// ---------- print：真机打印 ----------
static int DoPrint(const wchar_t* pdf, const wchar_t* printer, int argc, wchar_t** argv) {
  std::vector<BYTE> dmBuf, dmBuf2;
  DEVMODEW& dm = *DevModeBuf(dmBuf, printer);
  if (DocumentPropertiesW(NULL, NULL, (LPWSTR)printer, &dm, NULL, DM_OUT_BUFFER) != IDOK) {
    wprintf(L"[x] DocumentProperties failed\n"); return 1;
  }
  // 五项选项 → DEVMODE
  int copies = ArgInt(argc, argv, L"--copies", 1);
  dm.dmCopies = (short)copies; dm.dmFields |= DM_COPIES;
  if (ArgFlag(argc, argv, L"--color")) { dm.dmColor = DMCOLOR_COLOR; dm.dmFields |= DM_COLOR; }
  if (ArgFlag(argc, argv, L"--mono"))  { dm.dmColor = DMCOLOR_MONOCHROME; dm.dmFields |= DM_COLOR; }
  const wchar_t* dup = ArgVal(argc, argv, L"--duplex");
  if (dup) {
    dm.dmDuplex = (_wcsicmp(dup, L"short") == 0) ? DMDUP_HORIZONTAL : DMDUP_VERTICAL;
    dm.dmFields |= DM_DUPLEX;
  }
  const wchar_t* paper = ArgVal(argc, argv, L"--paper");
  if (paper) {
    WORD code = DMPAPER_A4;
    if (_wcsicmp(paper, L"A3") == 0) code = DMPAPER_A3;
    else if (_wcsicmp(paper, L"51") == 0 || _wcsicmp(paper, L"5x7") == 0) code = 51;
    else if (iswdigit(paper[0])) code = (WORD)_wtoi(paper);
    dm.dmPaperSize = code; dm.dmFields |= DM_PAPERSIZE;
  }
  // 合并驱动能力（避免驱动把不支持的字段清零后误用）
  DEVMODEW& out = *DevModeBuf(dmBuf2, printer);
  if (DocumentPropertiesW(NULL, NULL, (LPWSTR)printer, &out, &dm,
                          DM_IN_BUFFER | DM_OUT_BUFFER) != IDOK) {
    wprintf(L"[x] DocumentProperties merge failed\n"); return 1;
  }
  HDC hdc = CreateDCW(L"WINSPOOL", printer, NULL, &out);
  if (!hdc) { wprintf(L"[x] CreateDC failed err=%lu\n", GetLastError()); return 1; }
  int dpiX = GetDeviceCaps(hdc, LOGPIXELSX), dpiY = GetDeviceCaps(hdc, LOGPIXELSY);
  int physW = GetDeviceCaps(hdc, PHYSICALWIDTH), physH = GetDeviceCaps(hdc, PHYSICALHEIGHT);
  int offX = GetDeviceCaps(hdc, PHYSICALOFFSETX), offY = GetDeviceCaps(hdc, PHYSICALOFFSETY);
  wprintf(L"[i] printer dc %dx%d px @ %dx%d dpi, margins %d/%d, copies=%d color=%d duplex=%d paper=%d\n",
          physW, physH, dpiX, dpiY, offX, offY, out.dmCopies, out.dmColor, out.dmDuplex, out.dmPaperSize);
  DOCINFOW di = { sizeof(di), (LPWSTR)L"CrossLinkPrintJob", NULL, NULL, 0 };
  if (StartDocW(hdc, &di) <= 0) { wprintf(L"[x] StartDoc failed\n"); DeleteDC(hdc); return 1; }
  std::vector<int> pages = ParsePages(ArgVal(argc, argv, L"--pages"), 0);
  // 需要先知道页数：打开一次拿 total
  char utf8[MAX_PATH];
  WideCharToMultiByte(CP_UTF8, 0, pdf, -1, utf8, sizeof(utf8), NULL, NULL);
  FPDF_HANDLE doc = fpdf_Load(utf8, NULL);
  if (!doc) { wprintf(L"[x] load pdf failed\n"); AbortDoc(hdc); DeleteDC(hdc); return 1; }
  int total = fpdf_PageCount(doc);
  pages = ParsePages(ArgVal(argc, argv, L"--pages"), total);
  for (int idx : pages) {
    FPDF_HANDLE page = fpdf_LoadPage(doc, idx);
    double wpt = 0, hpt = 0; fpdf_PageSize(doc, idx, &wpt, &hpt);
    double wpix = wpt * dpiX / 72.0, hpix = hpt * dpiY / 72.0;
    int x, y, w, h;
    if (ArgFlag(argc, argv, L"--raw100")) {
      // 正式策略：客户端驱动已排好版，1:1 铺到纸张原点，不缩放不居中
      x = 0; y = 0; w = (int)wpix; h = (int)hpix;
    } else {
      double areaW = physW - 2.0 * offX, areaH = physH - 2.0 * offY;
      double scale = min(areaW / wpix, areaH / hpix);
      w = (int)(wpix * scale); h = (int)(hpix * scale);
      x = offX + (int)((areaW - w) / 2); y = offY + (int)((areaH - h) / 2);
    }
    StartPage(hdc);
    fpdf_Render(hdc, page, x, y, w, h, 0, 2 | 4);
    EndPage(hdc);
    fpdf_ClosePage(page);
    wprintf(L"[i] printed page %d\n", idx + 1);
  }
  fpdf_CloseDoc(doc);
  int rc = EndDoc(hdc);
  DeleteDC(hdc);
  if (rc <= 0) { wprintf(L"[x] EndDoc failed\n"); return 1; }
  wprintf(L"[OK] job submitted to %ls\n", printer);
  return 0;
}

int wmain(int argc, wchar_t** argv) {
  if (argc < 2) { wprintf(L"usage: printspike printers|caps|render|print ...\n"); return 2; }
  setvbuf(stdout, NULL, _IONBF, 0);
  const wchar_t* mode = argv[1];
  if (wcscmp(mode, L"printers") == 0) return DoPrinters();
  if (wcscmp(mode, L"caps") == 0 && argc >= 3) return DoCaps(argv[2]);
  if (!LoadPdfium(L"pdfium.dll")) return 1;
  if (wcscmp(mode, L"render") == 0 && argc >= 4)
    return DoRender(argv[2], argv[3], ArgVal(argc, argv, L"--pages"));
  if (wcscmp(mode, L"print") == 0 && argc >= 4)
    return DoPrint(argv[2], argv[3], argc, argv);
  wprintf(L"bad args\n"); return 2;
}
