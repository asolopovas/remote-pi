import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cockpit/app/cockpit/domain/contracts/update_checker.dart';
import 'package:cockpit/app/cockpit/domain/entities/update_info.dart';

/// Manual update checks are disabled unless the distributor explicitly supplies
/// an owned HTTPS manifest URL. No default feed or network client is used.
/// Busca o `latest.json` via HTTPS (dart:io, sem dep extra). Timeout curto;
/// qualquer falha → `null` (nunca lança), pra que o aviso seja totalmente
/// silencioso quando offline/indisponível.
class UpdateCheckerImpl implements UpdateChecker {
  const UpdateCheckerImpl({
    this.manifestUrl,
    this.timeout = const Duration(seconds: 5),
  });

  final String? manifestUrl;
  final Duration timeout;

  @override
  Future<UpdateInfo?> fetchLatest() async {
    final url = manifestUrl;
    if (url == null || url.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      return null;
    }
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      // Never silently delegate feed authority to a redirect destination.
      request.followRedirects = false;
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      return UpdateInfo.fromJson(jsonDecode(body));
    } catch (_) {
      // sem rede / 404 / JSON inválido / schema errado → silencioso.
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
