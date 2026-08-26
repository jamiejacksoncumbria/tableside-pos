import 'windows_print_queue.dart';
import 'windows_print_queue_stub.dart'
    if (dart.library.io) 'windows_print_queue_native.dart'
    as implementation;

WindowsPrintQueue createWindowsPrintQueue() =>
    implementation.createWindowsPrintQueue();
