import 'package:app/domain/entities/update_info.dart';

/// Busca o manifest de release (`latest.json`). Contrato no domínio; impl
/// (HTTP) em `data/update/`. **Best-effort**: qualquer falha (sem rede, 404,
/// JSON inválido, schema errado) devolve `null` — nunca lança.
abstract class UpdateChecker {
  Future<UpdateInfo?> fetchLatest();
}
