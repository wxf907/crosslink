# pdfium (vendored)

来源: https://github.com/bblanchon/pdfium-binaries (BSD-3 许可, 见 LICENSE 与 licenses/)。
版本: 见 VERSION 文件。

预编译 pdfium.dll (win-x64) + 头文件。vendor 进仓库的原因：
构建机访问 GitHub 不稳定，必须保证 `flutter build windows` 离线可复现。
打印引擎（windows/runner/print_channel.cpp）用它把 PDF 页面渲染到打印机 DC。

更新方式：从上述仓库下载对应平台 tgz，替换 pdfium.dll 与 include/，同步 VERSION。
