import 'package:app/domain/contracts/url_opener.dart';
import 'package:url_launcher/url_launcher.dart';

/// Abre URLs externas via `url_launcher` em modo navegador/app externo —
/// usado pelo aviso de update pra baixar o `RemotePi.apk` direto. Best-effort:
/// URL inválida ou plataforma sem handler → `false` (a UI já tem fallback).
class UrlLauncherOpener implements UrlOpener {
  const UrlLauncherOpener();

  @override
  Future<bool> open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
