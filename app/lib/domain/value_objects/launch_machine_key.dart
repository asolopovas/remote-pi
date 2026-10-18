import 'dart:convert';

/// Public identity within the current paired owner and effective relay. Legacy
/// QR relay URLs, names, cwd and room identifiers are deliberately not inputs.
String? launchMachineKey(String epk, String effectiveRelay) {
  try {
    final bytes = base64.decode(base64.normalize(epk));
    if (bytes.length != 32) return null;
    final uri = Uri.parse(effectiveRelay);
    final scheme = switch (uri.scheme) {
      'wss' => 'https',
      'ws' => 'http',
      final s => s,
    };
    if (!['http', 'https'].contains(scheme) || uri.host.isEmpty) return null;
    final port = uri.hasPort ? uri.port : (scheme == 'https' ? 443 : 80);
    return '$scheme://${uri.host.toLowerCase()}:$port${uri.path.replaceAll(RegExp(r"/+$"), "")}|${base64.encode(bytes)}';
  } on FormatException {
    return null;
  }
}
