import 'dart:io';

/// Returns the most likely private IPv4 address for a venue hub.
///
/// Network-interface enumeration can include VPN, emulator and virtual-switch
/// adapters. Physical Wi-Fi/Ethernet names are preferred and known virtual
/// adapters are penalised. The manager still confirms that the selected
/// address has a DHCP reservation before it is saved as trusted hub metadata.
Future<String?> preferredPrivateLanAddress() async {
  final candidates = <({String address, int score})>[];
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  );
  for (final interface in interfaces) {
    final name = interface.name.toLowerCase();
    for (final address in interface.addresses) {
      final value = address.address;
      if (!_isPrivateIpv4(value)) continue;
      var score = 0;
      if (name.contains('wi-fi') ||
          name.contains('wifi') ||
          name.contains('wlan') ||
          name.contains('ethernet') ||
          RegExp(r'^eth\d+$').hasMatch(name)) {
        score += 20;
      }
      if (name.contains('virtual') ||
          name.contains('vethernet') ||
          name.contains('docker') ||
          name.contains('vmware') ||
          name.contains('hyper-v') ||
          name.contains('tunnel') ||
          name.contains('vpn') ||
          name.contains('bluetooth')) {
        score -= 30;
      }
      candidates.add((address: value, score: score));
    }
  }
  if (candidates.isEmpty) return null;
  candidates.sort((a, b) => b.score.compareTo(a.score));
  return candidates.first.address;
}

bool _isPrivateIpv4(String address) {
  final parts = address.split('.').map(int.tryParse).toList(growable: false);
  if (parts.length != 4 || parts.any((part) => part == null)) return false;
  final first = parts[0]!;
  final second = parts[1]!;
  return first == 10 ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 192 && second == 168);
}
