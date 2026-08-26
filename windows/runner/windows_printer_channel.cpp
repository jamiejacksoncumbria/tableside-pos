#include "windows_printer_channel.h"

#include <windows.h>
#include <winspool.h>

#include <algorithm>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include <flutter/standard_method_codec.h>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return L"";
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                        value.data(),
                                        static_cast<int>(value.size()), nullptr,
                                        0);
  if (count <= 0) return L"";
  std::wstring result(static_cast<size_t>(count), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), result.data(), count);
  return result;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return "";
  const int count = WideCharToMultiByte(CP_UTF8, 0, value.data(),
                                        static_cast<int>(value.size()), nullptr,
                                        0, nullptr, nullptr);
  if (count <= 0) return "";
  std::string result(static_cast<size_t>(count), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      result.data(), count, nullptr, nullptr);
  return result;
}

std::string WindowsError(DWORD code) {
  LPWSTR buffer = nullptr;
  const DWORD length = FormatMessageW(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
          FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr, code, 0, reinterpret_cast<LPWSTR>(&buffer), 0, nullptr);
  if (length == 0 || buffer == nullptr) {
    return "Windows error " + std::to_string(code) + ".";
  }
  std::wstring message(buffer, length);
  LocalFree(buffer);
  while (!message.empty() &&
         (message.back() == L'\r' || message.back() == L'\n' ||
          message.back() == L' ')) {
    message.pop_back();
  }
  return WideToUtf8(message);
}

const EncodableValue* FindArgument(const EncodableMap& arguments,
                                   const char* key) {
  const auto found = arguments.find(EncodableValue(key));
  return found == arguments.end() ? nullptr : &found->second;
}

std::optional<std::string> StringArgument(const EncodableMap& arguments,
                                          const char* key) {
  const EncodableValue* value = FindArgument(arguments, key);
  if (value == nullptr) return std::nullopt;
  const auto text = std::get_if<std::string>(value);
  if (text == nullptr || text->empty()) return std::nullopt;
  return *text;
}

std::optional<std::vector<std::wstring>> TextLinesArgument(
    const EncodableMap& arguments) {
  const EncodableValue* value = FindArgument(arguments, "lines");
  if (value == nullptr) return std::nullopt;
  const auto lines = std::get_if<EncodableList>(value);
  if (lines == nullptr || lines->size() > 500) return std::nullopt;
  std::vector<std::wstring> result;
  result.reserve(lines->size());
  for (const EncodableValue& line : *lines) {
    const auto text = std::get_if<std::string>(&line);
    if (text == nullptr || text->size() > 1000) return std::nullopt;
    result.push_back(Utf8ToWide(*text));
  }
  return result;
}

std::wstring DefaultPrinterName() {
  DWORD character_count = 0;
  GetDefaultPrinterW(nullptr, &character_count);
  if (character_count == 0) return L"";
  std::wstring printer(character_count, L'\0');
  if (!GetDefaultPrinterW(printer.data(), &character_count)) return L"";
  if (!printer.empty() && printer.back() == L'\0') printer.pop_back();
  return printer;
}

EncodableList InstalledPrinters() {
  DWORD byte_count = 0;
  DWORD printer_count = 0;
  constexpr DWORD flags = PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS;
  if (EnumPrintersW(flags, nullptr, 2, nullptr, 0, &byte_count,
                    &printer_count) ||
      GetLastError() != ERROR_INSUFFICIENT_BUFFER || byte_count == 0) {
    return EncodableList();
  }
  std::vector<BYTE> buffer(byte_count);
  if (!EnumPrintersW(flags, nullptr, 2, buffer.data(), byte_count, &byte_count,
                     &printer_count)) {
    return EncodableList();
  }
  const auto* printers =
      reinterpret_cast<const PRINTER_INFO_2W*>(buffer.data());
  const std::wstring default_printer = DefaultPrinterName();
  EncodableList result;
  result.reserve(printer_count);
  for (DWORD index = 0; index < printer_count; ++index) {
    const PRINTER_INFO_2W& printer = printers[index];
    if (printer.pPrinterName == nullptr) continue;
    EncodableMap entry;
    const std::wstring name(printer.pPrinterName);
    entry[EncodableValue("name")] = EncodableValue(WideToUtf8(name));
    entry[EncodableValue("driverName")] = EncodableValue(
        WideToUtf8(printer.pDriverName == nullptr ? L"" : printer.pDriverName));
    entry[EncodableValue("portName")] = EncodableValue(
        WideToUtf8(printer.pPortName == nullptr ? L"" : printer.pPortName));
    entry[EncodableValue("isDefault")] = EncodableValue(name == default_printer);
    result.emplace_back(entry);
  }
  return result;
}

bool PrintText(const std::wstring& printer_name, const std::wstring& title,
               const std::vector<std::wstring>& lines, std::string* error) {
  HDC printer_dc =
      CreateDCW(L"WINSPOOL", printer_name.c_str(), nullptr, nullptr);
  if (printer_dc == nullptr) {
    *error = "Windows could not open the selected printer: " +
             WindowsError(GetLastError());
    return false;
  }

  DOCINFOW document = {};
  document.cbSize = sizeof(document);
  document.lpszDocName = title.c_str();
  if (StartDocW(printer_dc, &document) <= 0) {
    *error = "Windows could not start the print job: " +
             WindowsError(GetLastError());
    DeleteDC(printer_dc);
    return false;
  }

  const auto abort_document = [&]() {
    AbortDoc(printer_dc);
    DeleteDC(printer_dc);
  };
  if (StartPage(printer_dc) <= 0) {
    *error = "Windows could not start the receipt page: " +
             WindowsError(GetLastError());
    abort_document();
    return false;
  }

  const int dpi_y = std::max(72, GetDeviceCaps(printer_dc, LOGPIXELSY));
  HFONT font = CreateFontW(-MulDiv(9, dpi_y, 72), 0, 0, 0, FW_NORMAL, FALSE,
                           FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                           CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY,
                           FF_DONTCARE, L"Segoe UI");
  HGDIOBJ previous_font = font == nullptr ? nullptr : SelectObject(printer_dc, font);
  const int left = std::max(8, GetDeviceCaps(printer_dc, PHYSICALOFFSETX) + 8);
  const int top = std::max(8, GetDeviceCaps(printer_dc, PHYSICALOFFSETY) + 8);
  const int right = std::max(left + 100,
                             GetDeviceCaps(printer_dc, PHYSICALOFFSETX) +
                                 GetDeviceCaps(printer_dc, HORZRES) - 8);
  const int page_bottom = std::max(top + 100,
                                   GetDeviceCaps(printer_dc, PHYSICALOFFSETY) +
                                       GetDeviceCaps(printer_dc, VERTRES) - 8);
  TEXTMETRICW metrics = {};
  GetTextMetricsW(printer_dc, &metrics);
  const int line_gap = std::max(3, static_cast<int>(metrics.tmHeight / 4));
  int y = top;

  for (const std::wstring& line : lines) {
    if (line.empty()) {
      y += metrics.tmHeight + line_gap;
      continue;
    }
    RECT measure = {left, y, right, page_bottom};
    const int height = DrawTextW(printer_dc, line.c_str(),
                                 static_cast<int>(line.size()), &measure,
                                 DT_LEFT | DT_WORDBREAK | DT_NOPREFIX |
                                     DT_CALCRECT);
    if (height <= 0) continue;
    if (y + height > page_bottom) {
      if (EndPage(printer_dc) <= 0 || StartPage(printer_dc) <= 0) {
        *error = "Windows could not continue the receipt print job: " +
                 WindowsError(GetLastError());
        if (previous_font != nullptr) SelectObject(printer_dc, previous_font);
        if (font != nullptr) DeleteObject(font);
        abort_document();
        return false;
      }
      y = top;
    }
    RECT draw = {left, y, right, page_bottom};
    DrawTextW(printer_dc, line.c_str(), static_cast<int>(line.size()), &draw,
              DT_LEFT | DT_WORDBREAK | DT_NOPREFIX);
    y += height + line_gap;
  }

  if (previous_font != nullptr) SelectObject(printer_dc, previous_font);
  if (font != nullptr) DeleteObject(font);
  if (EndPage(printer_dc) <= 0 || EndDoc(printer_dc) <= 0) {
    *error = "Windows could finish the print job: " + WindowsError(GetLastError());
    DeleteDC(printer_dc);
    return false;
  }
  DeleteDC(printer_dc);
  return true;
}

}  // namespace

WindowsPrinterChannel::WindowsPrinterChannel(flutter::BinaryMessenger* messenger)
    : channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "tableside/windows_printer",
          &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() == "listPrinters") {
          result->Success(EncodableValue(InstalledPrinters()));
          return;
        }
        if (call.method_name() != "printText") {
          result->NotImplemented();
          return;
        }
        const auto* arguments = std::get_if<EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("invalid-arguments", "A printer name and receipt lines are required.");
          return;
        }
        const auto printer_name = StringArgument(*arguments, "printerName");
        const auto title = StringArgument(*arguments, "title");
        const auto lines = TextLinesArgument(*arguments);
        if (!printer_name.has_value() || !title.has_value() || !lines.has_value()) {
          result->Error("invalid-arguments", "A valid printer name, title and receipt lines are required.");
          return;
        }
        std::string error;
        if (!PrintText(Utf8ToWide(*printer_name), Utf8ToWide(*title), *lines,
                       &error)) {
          result->Error("print-failed", error);
          return;
        }
        result->Success();
      });
}

WindowsPrinterChannel::~WindowsPrinterChannel() = default;
