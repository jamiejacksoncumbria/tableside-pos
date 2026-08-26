#ifndef RUNNER_WINDOWS_PRINTER_CHANNEL_H_
#define RUNNER_WINDOWS_PRINTER_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// Bridges the app to Windows' installed print queues. USB and TCP/IP printers
// are both exposed by Windows as queues once their driver/port is installed.
class WindowsPrinterChannel {
 public:
  explicit WindowsPrinterChannel(flutter::BinaryMessenger* messenger);
  ~WindowsPrinterChannel();

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_WINDOWS_PRINTER_CHANNEL_H_
