import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app/domain/contracts/agent_repository.dart';
import 'package:app/routing/adaptive.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'viewmodels/agents_viewmodel.dart';

class AgentsTarget {
  const AgentsTarget(
    this.peer,
    this.room,
    this.host,
    this.session, {
    this.freshStart = false,
    this.preferredRoom,
    this.resolveOrigin = false,
    this.recoverChild = false,
  });
  final bool freshStart;
  final String? preferredRoom;
  final bool resolveOrigin, recoverChild;
  final String peer, room, host, session;
}

class AgentsPage extends StatefulWidget {
  const AgentsPage({super.key, required this.target});
  final AgentsTarget target;
  @override
  State<AgentsPage> createState() => _AgentsPageState();
}

enum _LauncherAction { agents, lock }

class _AgentsPageState extends State<AgentsPage> with WidgetsBindingObserver {
  final _pin = TextEditingController();
  final _confirmPin = TextEditingController();
  AgentsViewModel? _vm;
  String? _authority;
  final _pinFocus = FocusNode();
  final _confirmFocus = FocusNode();
  bool _revealed = false, _pinVisited = false, _confirmVisited = false;
  bool _autofocusUsed = false;
  bool _allowPop = false, _leaving = false;
  Timer? _cooldownTimer;
  int _cooldownDeadline = 0;

  bool get _validPin => RegExp(r'^\d{6,12}$').hasMatch(_pin.text);
  bool get _coolingDown =>
      (_vm?.security?.cooldownUntil ?? 0) >
      DateTime.now().millisecondsSinceEpoch;

  void _syncCooldown(int deadline) {
    if (_cooldownDeadline == deadline) return;
    _cooldownDeadline = deadline;
    _cooldownTimer?.cancel();
    if (deadline <= DateTime.now().millisecondsSinceEpoch) return;
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (!_coolingDown) timer.cancel();
      setState(() {});
    });
  }

  Widget _cooldownNotice() {
    final seconds =
        ((_cooldownDeadline - DateTime.now().millisecondsSinceEpoch) / 1000)
            .ceil();
    return Text(
      'Too many attempts. Try again in ${seconds > 0 ? seconds : 0}s.',
    );
  }

  Widget _pinField({
    required bool confirm,
    required bool setup,
    required bool disabled,
    required AgentsViewModel vm,
  }) {
    final autofocus = !_autofocusUsed && !disabled && !confirm;
    if (autofocus) _autofocusUsed = true;
    return TextField(
      key: Key(
        setup
            ? (confirm ? 'launcher-confirm-pin' : 'launcher-create-pin')
            : 'launcher-pin',
      ),
      controller: confirm ? _confirmPin : _pin,
      focusNode: confirm ? _confirmFocus : _pinFocus,
      autofocus: autofocus,
      enabled: !disabled,
      obscureText: !_revealed,
      enableSuggestions: false,
      autocorrect: false,
      enableIMEPersonalizedLearning: false,
      autofillHints: const [],
      keyboardType: TextInputType.number,
      textInputAction: setup && !confirm
          ? TextInputAction.next
          : TextInputAction.done,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      maxLength: 12,
      decoration: InputDecoration(
        labelText: setup ? (confirm ? 'Confirm PIN' : 'Create PIN') : 'PIN',
        helperText: confirm ? null : '6–12 digits',
        counterText: '',
        errorText: confirm
            ? (_confirmVisited && _pin.text != _confirmPin.text
                  ? 'PINs do not match.'
                  : null)
            : (_pinVisited && !_validPin ? 'Use 6–12 digits.' : null),
        suffixIcon: IconButton(
          tooltip: _revealed ? 'Hide PIN' : 'Show PIN',
          onPressed: disabled
              ? null
              : () => setState(() => _revealed = !_revealed),
          icon: Icon(_revealed ? Icons.visibility_off : Icons.visibility),
        ),
      ),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) {
        if (disabled ||
            _coolingDown ||
            vm.state.busy ||
            vm.state.invalid ||
            _targetChanged) {
          return;
        }
        if (setup && !confirm) {
          _confirmFocus.requestFocus();
        } else if (setup) {
          _createPin(vm);
        } else {
          _unlock(vm);
        }
      },
    );
  }

  void _clearPins() {
    _pin.clear();
    _confirmPin.clear();
    _revealed = false;
    _pinVisited = false;
    _confirmVisited = false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final vm = context.read<AgentsViewModel>();
    if (!identical(vm, _vm)) {
      _vm?.removeListener(_securityChanged);
      _clearPins();
      _vm = vm;
      vm.addListener(_securityChanged);
      _securityChanged();
    }
  }

  void _securityChanged() {
    final vm = _vm!;
    final security = vm.security;
    _syncCooldown(security?.cooldownUntil ?? 0);
    final authority =
        '${security?.launcherId}:${security?.epoch}:${security?.configured}:${security?.pinSetup}:${security?.unlocked}:${security?.expiresAt}:${security?.cooldownUntil}:${vm.state.invalid}';
    if (_authority != authority || vm.state.busy || vm.state.invalid) {
      _clearPins();
    }
    _authority = authority;
  }

  String? _selected, _identity, _projectDefinition;
  ({String id, String identity, String definition})? _selectionCandidate;
  bool _confirming = false, _targetChanged = false;

  String _definition(LauncherProject project) =>
      '${project.projectId}:${project.name}:${project.cwd}:${project.allowedFolders.join('\u0000')}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pinFocus.addListener(() {
      if (!_pinFocus.hasFocus && mounted && _pin.text.isNotEmpty) {
        setState(() => _pinVisited = true);
      }
    });
    _confirmFocus.addListener(() {
      if (!_confirmFocus.hasFocus && mounted && _confirmPin.text.isNotEmpty) {
        setState(() => _confirmVisited = true);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final vm = context.read<AgentsViewModel>();
        if (widget.target.freshStart) {
          vm.resolveFresh(
            widget.target.peer,
            preferredRoom: widget.target.preferredRoom,
          );
        } else if (widget.target.resolveOrigin) {
          vm.resolveHost(
            widget.target.peer,
            widget.target.room,
            returnToChild: widget.target.recoverChild,
          );
        } else {
          vm.initialize(widget.target.peer, widget.target.room);
        }
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clearPins();
    _vm?.removeListener(_securityChanged);
    _cooldownTimer?.cancel();
    _pinFocus.dispose();
    _confirmFocus.dispose();
    _pin.dispose();
    _confirmPin.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _clearPins();
      _vm?.invalidateRecovery();
      _pinFocus.unfocus();
      _confirmFocus.unfocus();
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant AgentsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.target.peer != widget.target.peer ||
        oldWidget.target.room != widget.target.room) {
      _clearPins();
      _selected = null;
      _selectionCandidate = null;
      _targetChanged = true;
      final vm = context.read<AgentsViewModel>();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) vm.rejectTargetChange();
      });
    }
  }

  Future<void> _unlock(AgentsViewModel vm) async {
    if (vm.state.busy || vm.state.invalid || _targetChanged || _coolingDown) {
      return;
    }
    if (!_validPin) {
      setState(() => _pinVisited = true);
      return;
    }
    var pin = _pin.text;
    _clearPins();
    final pending = vm.unlock(pin);
    pin = '';
    await pending;
    if (mounted &&
        widget.target.recoverChild &&
        vm.unlocked &&
        !vm.state.invalid) {
      await _returnToChild(vm);
    }
  }

  Future<void> _returnToChild(AgentsViewModel vm) async {
    if (_leaving) return;
    _leaving = true;
    final status = await vm.finishRecovery();
    if (!mounted) return;
    if (status == null) {
      _leaving = false;
      return;
    }
    // Child verification, not parent unlock, is the only success evidence.
    _popAfterReturn(
      status.canStop
          ? null
          : 'Child access not confirmed. The selected host may not be its launching host. Check access; do not retry PIN here.',
    );
  }

  void _popAfterReturn(String? message) {
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.pop(message);
    });
  }

  Future<void> _leaveLauncher() async {
    final vm = context.read<AgentsViewModel>();
    if (_leaving || vm.state.busy) return;
    _leaving = true;
    _clearPins();
    final returned = await vm.cancelRecovery();
    if (!mounted) return;
    if (returned) {
      _popAfterReturn(null);
    } else {
      // Never expose the old child chat while the transport still targets a parent.
      context.go('/home');
    }
  }

  Future<void> _createPin(AgentsViewModel vm) async {
    if (vm.state.busy || vm.state.invalid || _targetChanged || _coolingDown) {
      return;
    }
    if (!RegExp(r'^\d{6,12}$').hasMatch(_pin.text) ||
        _pin.text != _confirmPin.text) {
      setState(() {
        _pinVisited = true;
        _confirmVisited = true;
      });
      return;
    }
    var pin = _pin.text;
    _clearPins();
    final pending = vm.initializePin(pin);
    pin = '';
    await pending;
  }

  Future<void> _confirm({ManagedAgent? stop}) async {
    if (!mounted || _confirming || _targetChanged) return;
    final vm = context.read<AgentsViewModel>();
    if (!vm.unlocked || vm.state.invalid || vm.state.busy) return;
    final projectId = _selected;
    final projects = vm.projects.where((p) => p.projectId == projectId);
    final project = projects.firstOrNull;
    if (stop == null && project == null) return;
    final identity = _identity, definition = _projectDefinition;
    final launcherId = vm.security?.launcherId, epoch = vm.security?.epoch;
    final warnedUnknown = vm.hasUnknownLaunch;
    final extraFolders =
        project?.allowedFolders.where((path) => path != project.cwd).toList() ??
        const <String>[];
    setState(() => _confirming = true);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        scrollable: true,
        title: Text(stop == null ? 'Start agent?' : 'Stop agent?'),
        content: Text(
          stop == null
              ? '${warnedUnknown ? 'Earlier start unconfirmed. Starting another may create a second agent.\n\n' : ''}${widget.target.host} · ${vm.launchSession ?? vm.launchRoom ?? widget.target.session} · ${project!.name}\n${project.cwd}${extraFolders.isEmpty ? '' : '\nAccess: ${extraFolders.join(', ')}'}\n\nStops when this launcher closes or reloads.'
              : '${stop.name}\nStops this agent only.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(stop == null ? 'Start' : 'Stop'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => _confirming = false);
    if (ok != true ||
        _targetChanged ||
        identity != _identity ||
        vm.security?.launcherId != launcherId ||
        vm.security?.epoch != epoch) {
      return;
    }
    if (stop != null) {
      await vm.stop(stop.agentId, confirmed: true);
      return;
    }
    if (definition != _projectDefinition || _selected != projectId) return;
    final agent = await vm.launch(
      projectId!,
      null,
      confirmed: true,
      acknowledgeUnknown: warnedUnknown,
    );
    if (!mounted || agent == null) return;
    if (_targetChanged) return;
    final opened = await vm.openAgent(agent);
    if (!mounted || !opened || _targetChanged) return;
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      context.read<SessionSelection>().select(
        widget.target.peer,
        agent.roomId,
        agent.name,
        widget.target.host,
        true,
      );
      final wide = isWideLayout(context);
      router.go('/home');
      if (!wide) {
        router.push(
          '/chat',
          extra: {
            'title': agent.name,
            'device': widget.target.host,
            'online': true,
          },
        );
      }
    }
  }

  void _showAgents(AgentsViewModel vm) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ChangeNotifierProvider<AgentsViewModel>.value(
          value: vm,
          child: _RunningAgentsPage(
            host: widget.target.host,
            onStop: (agent) => _confirm(stop: agent),
          ),
        ),
      ),
    );
  }

  void _reconcileSelection(AgentsViewModel vm, String identity) {
    final state = vm.state;
    if (vm.reconcilingSelection && !state.invalid && !_targetChanged) {
      if (_selected != null &&
          _identity != null &&
          _projectDefinition != null) {
        _selectionCandidate = (
          id: _selected!,
          identity: _identity!,
          definition: _projectDefinition!,
        );
      }
      _selected = null;
      _clearPins();
    } else {
      final candidate = _selectionCandidate;
      _selectionCandidate = null;
      if (candidate != null &&
          !state.invalid &&
          !state.needsReconciliation &&
          !_targetChanged &&
          vm.unlocked &&
          candidate.identity == identity &&
          vm.projects.any(
            (p) =>
                p.projectId == candidate.id &&
                _definition(p) == candidate.definition,
          )) {
        _selected = candidate.id;
        _projectDefinition = candidate.definition;
        _identity = identity;
      }
      if (_identity != identity ||
          _selected != null &&
              !vm.projects.any(
                (p) =>
                    p.projectId == _selected &&
                    _definition(p) == _projectDefinition,
              )) {
        _selected = null;
        _clearPins();
      }
    }
    _identity = identity;
    if (state.invalid) _clearPins();
  }

  Widget _checkStatus(AgentsViewModel vm) => FilledButton(
    onPressed: vm.state.busy || vm.state.invalid || _targetChanged
        ? null
        : vm.refresh,
    child: const Text('Check status'),
  );

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<AgentsViewModel>();
    final identity =
        '${widget.target.peer}:${widget.target.room}:${vm.security?.launcherId}:${vm.security?.epoch}';
    _reconcileSelection(vm, identity);
    final state = vm.state;
    final disabled =
        state.busy || state.invalid || _confirming || _targetChanged;
    final agents =
        vm.state.availability?.agents
            .where((a) => a.state != 'stopped')
            .toList() ??
        const <ManagedAgent>[];
    return PopScope(
      canPop: !widget.target.resolveOrigin || _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && widget.target.resolveOrigin) _leaveLauncher();
      },
      child: Scaffold(
        backgroundColor: context.colors.bg,
        appBar: AppBar(
          leading: widget.target.resolveOrigin
              ? BackButton(onPressed: _leaveLauncher)
              : null,
          title: Text(
            widget.target.recoverChild
                ? 'Launching host access'
                : 'Start agent',
          ),
          actions: [
            IconButton(
              tooltip: 'Refresh',
              onPressed: disabled ? null : vm.refresh,
              icon: const Icon(Icons.refresh),
            ),
            if (vm.unlocked && !state.invalid)
              PopupMenuButton<_LauncherAction>(
                tooltip: 'Agent options',
                enabled: !disabled,
                onSelected: (action) {
                  switch (action) {
                    case _LauncherAction.agents:
                      _showAgents(vm);
                    case _LauncherAction.lock:
                      _clearPins();
                      vm.lock();
                  }
                },
                itemBuilder: (_) => [
                  if (agents.isNotEmpty)
                    const PopupMenuItem(
                      value: _LauncherAction.agents,
                      child: Text('Started here'),
                    ),
                  const PopupMenuItem(
                    value: _LauncherAction.lock,
                    child: Text('Lock access'),
                  ),
                ],
              ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: AppSpacing.md,
            children: [
              Text('Host: ${widget.target.host}', style: context.typo.sansBody),
              Text(
                'Session: ${vm.launchSession ?? vm.launchRoom ?? widget.target.session}',
                style: context.typo.sansBody,
              ),
              if (vm.security != null)
                Text(
                  vm.security!.launcherApi == null
                      ? 'Launcher API unknown · host update may be needed.'
                      : 'Launcher API ${vm.security!.launcherApi}',
                  style: context.typo.monoSmall,
                ),
              if (widget.target.recoverChild && vm.security != null)
                const Text('Access: this launcher only · 5 minutes'),
              ..._content(vm, disabled, agents),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _content(
    AgentsViewModel vm,
    bool disabled,
    List<ManagedAgent> agents,
  ) {
    final state = vm.state, security = vm.security;
    if (vm.choosingFreshSession) {
      return [
        Text(state.message ?? 'Choose launching session'),
        const Text('Choose launching session'),
        for (final session in vm.freshSessions)
          ListTile(
            title: Text(session.label),
            subtitle: Text(session.room),
            onTap: disabled ? null : () => vm.chooseFreshSession(session.room),
          ),
      ];
    }
    if (vm.choosingHost) {
      return [
        const Text(
          'Choose launching session. Origin unknown on this host version.',
        ),
        for (final choice in vm.hostChoices)
          ListTile(
            title: Text(choice.label),
            subtitle: Text(choice.room),
            onTap: () => vm.chooseHost(widget.target.peer, choice.room),
          ),
        if (vm.hostChoices.isEmpty)
          const Text('No live paired sessions. Check status from Home.'),
      ];
    }
    if (vm.recoveryError != null) {
      return [
        Text(vm.recoveryError!),
        TextButton(
          onPressed: _leaveLauncher,
          child: const Text('Back to sessions'),
        ),
      ];
    }
    if (state.busy || vm.resolvingHost) {
      return [
        const LinearProgressIndicator(),
        Semantics(
          liveRegion: true,
          child: Text(state.message ?? 'Checking status…'),
        ),
      ];
    }
    if (state.invalid || _targetChanged) {
      return [Text(state.message ?? 'Host changed. Reopen the launcher.')];
    }
    if (security == null) {
      return [Text(state.message ?? 'Host unavailable.'), _checkStatus(vm)];
    }
    if (widget.target.recoverChild && vm.unlocked) {
      return [
        const Text(
          'Access is scoped to this launching host, not the whole device.',
        ),
        FilledButton(
          onPressed: disabled ? null : () => _returnToChild(vm),
          child: const Text('Return & check access'),
        ),
      ];
    }
    if (widget.target.recoverChild && !security.configured) {
      return [
        const Text(
          'Host access unavailable. Check the launching host setup locally.',
        ),
        _checkStatus(vm),
      ];
    }
    if (!security.configured && security.pinSetup == PinSetup.available) {
      final cooldown =
          security.cooldownUntil > DateTime.now().millisecondsSinceEpoch;
      final valid = RegExp(r'^\d{6,12}$').hasMatch(_pin.text);
      final matches = _pin.text == _confirmPin.text;
      return [
        if (state.message != null) Text(state.message!),
        if (cooldown) _cooldownNotice(),
        for (final confirm in [false, true])
          _pinField(
            confirm: confirm,
            setup: true,
            disabled: disabled || cooldown,
            vm: vm,
          ),
        FilledButton(
          key: const Key('create-launcher-pin'),
          onPressed: disabled || cooldown || !valid || !matches
              ? null
              : () => _createPin(vm),
          child: const Text('Create PIN & unlock'),
        ),
      ];
    }
    if (!security.configured) {
      return [
        Text('Host setup required', style: context.typo.sansBody),
        Text(
          security.pinSetup == PinSetup.unavailable
              ? 'PIN storage unavailable. Inspect and repair it locally on the PC.'
              : 'Update the host for phone PIN setup, or create a PIN on the PC, then check status.',
        ),
        FilledButton.icon(
          key: const Key('copy-launcher-setup'),
          onPressed: () => Clipboard.setData(
            const ClipboardData(text: 'remote-pi-launcher pin-setup'),
          ),
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Copy setup command'),
        ),
        TextButton(onPressed: vm.refresh, child: const Text('Check status')),
      ];
    }
    if (!vm.unlocked) {
      final cooldown =
          security.cooldownUntil > DateTime.now().millisecondsSinceEpoch;
      return [
        if (state.message != null) Text(state.message!),
        if (cooldown) _cooldownNotice(),
        _pinField(
          confirm: false,
          setup: false,
          disabled: disabled || cooldown,
          vm: vm,
        ),
        FilledButton(
          onPressed: disabled || cooldown || !_validPin
              ? null
              : () => _unlock(vm),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(AppSpacing.tap),
          ),
          child: const Text('Unlock'),
        ),
      ];
    }
    if (!security.supportsNewLaunch) {
      return [const Text(newLaunchCompatibilityMessage), _checkStatus(vm)];
    }
    final availability = state.availability;
    if (availability?.available != true) {
      return [
        Text(state.message ?? availability?.reason ?? 'Launching unavailable.'),
        _checkStatus(vm),
      ];
    }
    if (vm.projects.isEmpty) {
      return [const Text('No approved projects on this PC.'), _checkStatus(vm)];
    }
    final full =
        agents
            .where((a) => a.state == 'running' || a.state == 'starting')
            .length >=
        availability!.maxAgents;
    return [
      if (state.message != null) Text(state.message!),
      if (state.message != null || state.needsReconciliation) _checkStatus(vm),
      RadioGroup<String>(
        groupValue: _selected,
        onChanged: (value) {
          if (disabled) return;
          setState(() {
            _selected = value;
            _projectDefinition = value == null
                ? null
                : _definition(
                    vm.projects.firstWhere((p) => p.projectId == value),
                  );
          });
        },
        child: Column(
          children: [
            for (final project in vm.projects)
              RadioListTile<String>(
                key: ValueKey('launch-project-${project.projectId}'),
                value: project.projectId,
                enabled: !disabled,
                selected: _selected == project.projectId,
                controlAffinity: ListTileControlAffinity.trailing,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                ),
                title: Text(project.name),
                subtitle: Text(
                  project.cwd,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.typo.monoSmall.copyWith(
                    color: context.colors.muted,
                  ),
                ),
              ),
          ],
        ),
      ),
      if (vm.hasUnknownLaunch)
        const Text(
          'Previous start unconfirmed. Retrying may create another agent.',
        ),
      if (full) ...[
        const Text('Agent limit reached.'),
        FilledButton(
          onPressed: disabled ? null : () => _showAgents(vm),
          child: const Text('View agents'),
        ),
      ] else
        FilledButton(
          key: const Key('launch-agent'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(AppSpacing.tap),
          ),
          onPressed: disabled || _selected == null || state.needsReconciliation
              ? null
              : () => _confirm(),
          child: const Text('Start agent'),
        ),
    ];
  }
}

class _RunningAgentsPage extends StatelessWidget {
  const _RunningAgentsPage({required this.host, required this.onStop});
  final String host;
  final ValueChanged<ManagedAgent> onStop;

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<AgentsViewModel>();
    final agents =
        vm.state.availability?.agents
            .where((a) => a.state != 'stopped')
            .toList() ??
        const <ManagedAgent>[];
    return Scaffold(
      backgroundColor: context.colors.bg,
      appBar: AppBar(title: const Text('Started here')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          Text(host, style: context.typo.monoSmall),
          if (vm.state.busy) const LinearProgressIndicator(),
          if (vm.state.invalid || !vm.unlocked)
            const Text('Unlock the host to manage agents.'),
          if (agents.isEmpty) const Text('No running agents.'),
          for (final agent in agents)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                agent.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${agent.state}${agent.error == null ? '' : ': ${agent.error}'}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: TextButton(
                onPressed: vm.state.busy || vm.state.invalid || !vm.unlocked
                    ? null
                    : () => onStop(agent),
                child: const Text('Stop'),
              ),
            ),
        ],
      ),
    );
  }
}
