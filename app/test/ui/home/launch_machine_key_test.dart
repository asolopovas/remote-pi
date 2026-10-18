import 'dart:convert';
import 'package:app/domain/value_objects/launch_machine_key.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('canonical 32-byte public identity, never labels or rooms', () {
    final bytes = List.filled(32, 255);
    final standard = base64.encode(bytes),
        url = base64Url.encode(bytes).replaceAll('=', '');
    expect(
      launchMachineKey(standard, 'https://EXAMPLE.com/'),
      launchMachineKey(url, 'wss://example.com:443'),
    );
    expect(
      launchMachineKey(standard, 'https://example.com'),
      isNot(
        launchMachineKey(
          base64.encode(List.filled(32, 1)),
          'https://example.com',
        ),
      ),
    );
    expect(
      launchMachineKey(standard, 'https://other.com'),
      isNot(launchMachineKey(standard, 'https://example.com')),
    );
    expect(launchMachineKey('not-a-key', 'https://example.com'), isNull);
    expect(launchMachineKey(base64.encode([1]), 'https://example.com'), isNull);
  });
}
