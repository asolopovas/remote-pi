import 'package:app/domain/entities/update_info.dart';

/// Estado do aviso de atualização in-app (plano 44). Só dois casos: escondido
/// (nada a mostrar — iOS, sem update, dispensado, manifest indisponível) ou
/// visível com o [UpdateInfo] a anunciar.
sealed class UpdateBannerState {
  const UpdateBannerState();
}

/// Nada a mostrar. `const` → canonicalizado, então `emit` dedupe por
/// identidade sem precisar de `==` manual.
final class UpdateBannerHidden extends UpdateBannerState {
  const UpdateBannerHidden();
}

/// Há uma versão maior, não dispensada, pra anunciar.
final class UpdateBannerVisible extends UpdateBannerState {
  const UpdateBannerVisible(this.info);

  final UpdateInfo info;

  // Igualdade por versão — re-emitir o mesmo manifest não dispara rebuild.
  @override
  bool operator ==(Object other) =>
      other is UpdateBannerVisible && other.info.version == info.version;

  @override
  int get hashCode => info.version.hashCode;
}
