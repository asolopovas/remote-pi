import 'package:app/domain/contracts/agent_repository.dart';

sealed class AgentsState {
  const AgentsState();
}

final class AgentsViewState extends AgentsState {
  const AgentsViewState({
    this.busy = false,
    this.invalid = false,
    this.needsReconciliation = false,
    this.availability,
    this.message,
  });
  final bool busy, invalid, needsReconciliation;
  final AgentAvailability? availability;
  final String? message;
}
