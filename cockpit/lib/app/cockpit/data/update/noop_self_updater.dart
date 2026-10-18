import '../../domain/contracts/self_updater.dart';

/// Sem self-update nativo (plataforma sem suporte ou sem configuração): [isSupported] é `false` e tudo é no-op. O
/// `UpdateViewModel` detecta isso e cai no caminho de notify + download manual
/// somente quando um feed próprio foi configurado no UpdateChecker.
/// Sem essa configuração, o padrão também não faz checks manuais de rede.
class NoopSelfUpdater implements SelfUpdater {
  const NoopSelfUpdater();

  @override
  bool get isSupported => false;

  @override
  SelfUpdateState get state => const SelfUpdateState.idle();

  @override
  Stream<SelfUpdateState> get changes => const Stream<SelfUpdateState>.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> checkForUpdates({bool inBackground = true}) async {}

  @override
  Future<void> applyUpdate() async {}

  @override
  void dispose() {}
}
