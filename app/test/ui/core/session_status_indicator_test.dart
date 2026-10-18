import 'package:app/ui/core/session_status_indicator.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'session status preserves working, reconnecting, online, offline priority',
    () {
      for (final working in [false, true]) {
        for (final reconnecting in [false, true]) {
          for (final online in [false, true]) {
            expect(
              SessionStatus.resolve(
                isWorking: working,
                isReconnecting: reconnecting,
                isOnline: online,
              ),
              working
                  ? SessionStatus.working
                  : reconnecting
                  ? SessionStatus.reconnecting
                  : online
                  ? SessionStatus.online
                  : SessionStatus.offline,
            );
          }
        }
      }
    },
  );

  for (final dark in [true, false]) {
    testWidgets(
      'working glyph spins without pulsing (${dark ? 'dark' : 'light'})',
      (tester) async {
        Future<void> show({
          bool reduce = false,
          bool accessible = false,
          SessionStatus status = SessionStatus.working,
        }) => tester.pumpWidget(
          MaterialApp(
            theme: dark ? buildDarkTheme() : buildLightTheme(),
            home: MediaQuery(
              data: MediaQueryData(
                disableAnimations: reduce,
                accessibleNavigation: accessible,
              ),
              child: Scaffold(
                body: Row(
                  children: [
                    SessionStatusIndicator(status: status),
                    Text(status.label),
                  ],
                ),
              ),
            ),
          ),
        );
        final semantics = tester.ensureSemantics();
        await show();
        expect(find.bySemanticsLabel('Working'), findsOneWidget);
        final icon = tester.widget<Icon>(find.byIcon(Icons.autorenew));
        expect(icon.color, (dark ? AppColors.dark : AppColors.light).working);
        final rotation = find.descendant(
          of: find.byType(SessionStatusIndicator),
          matching: find.byType(RotationTransition),
        );
        final turns = tester.widget<RotationTransition>(rotation).turns;
        final first = turns.value;
        await tester.pump(const Duration(milliseconds: 300));
        expect(turns.value, isNot(first));
        expect(
          tester.widget<Icon>(find.byIcon(Icons.autorenew)).color,
          icon.color,
        );
        await show(reduce: true);
        await tester.pump();
        final still = turns.value;
        await tester.pump(const Duration(seconds: 2));
        expect(turns.value, still);
        expect(turns.status, AnimationStatus.dismissed);
        expect(find.byIcon(Icons.autorenew), findsOneWidget);
        expect(find.bySemanticsLabel('Working'), findsOneWidget);
        await show(accessible: true);
        await tester.pump(const Duration(seconds: 2));
        expect(turns.value, still);
        await show();
        await tester.pump(const Duration(milliseconds: 300));
        expect(turns.value, isNot(still));
        await show(status: SessionStatus.reconnecting);
        await tester.pump();
        expect(rotation, findsNothing);
        expect(find.bySemanticsLabel('Reconnecting'), findsOneWidget);
        expect(turns.status, AnimationStatus.dismissed);
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
        semantics.dispose();
      },
    );
  }
}
