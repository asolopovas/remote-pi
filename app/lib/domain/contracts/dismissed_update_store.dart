/// Persiste qual versão de atualização o usuário **dispensou** (fechou o card).
/// Contrato no domínio; impl (storage seguro) em `data/update/`. O card não
/// reaparece pra essa versão, mas volta quando sair uma maior.
abstract class DismissedUpdateStore {
  /// A última versão dispensada, ou `null` se nenhuma.
  Future<String?> dismissedVersion();

  /// Marca [version] como dispensada.
  Future<void> dismiss(String version);
}
