/// Browsers cannot enumerate host network interfaces. Native Android and
/// Windows implementations are selected through the conditional export.
Future<String?> preferredPrivateLanAddress() async => null;
