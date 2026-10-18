// Plan-38 Fase 3 — the Home presence filter: a 3-pill segmented control and
// the per-tab empty state. Pure view widgets; `context.colors` falls back to
// the dark palette outside the themed tree, so a bare MaterialApp is enough.

import 'package:app/ui/home/states/home_state.dart';
import 'package:app/ui/home/widgets/home_filter_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HomeFilterTabs', () {
    Future<void> pump(
      WidgetTester tester, {
      HomeFilter filter = HomeFilter.online,
      ValueChanged<HomeFilter>? onSelected,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeFilterTabs(
              filter: filter,
              counts: (all: 3, online: 1, offline: 2),
              onSelected: onSelected ?? (_) {},
            ),
          ),
        ),
      );
    }

    testWidgets('renders the three tabs with their counts', (tester) async {
      await pump(tester);
      expect(find.text('All'), findsOneWidget);
      expect(find.text('Online'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);
      // Distinct counts so each digit maps to exactly one badge.
      expect(find.text('3'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('tapping a tab fires onSelected with that filter', (
      tester,
    ) async {
      HomeFilter? picked;
      await pump(tester, onSelected: (f) => picked = f);

      await tester.tap(find.text('Offline'));
      expect(picked, HomeFilter.offline);

      await tester.tap(find.text('All'));
      expect(picked, HomeFilter.all);

      await tester.tap(find.text('Online'));
      expect(picked, HomeFilter.online);
    });
  });

  group('HomeFilterEmptyState', () {
    Future<void> pump(WidgetTester tester, HomeFilter filter) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: HomeFilterEmptyState(filter: filter)),
        ),
      );
    }

    testWidgets('online tab → "No sessions online"', (tester) async {
      await pump(tester, HomeFilter.online);
      expect(find.text('No sessions online'), findsOneWidget);
    });

    testWidgets('offline tab → "No offline sessions"', (tester) async {
      await pump(tester, HomeFilter.offline);
      expect(find.text('No offline sessions'), findsOneWidget);
    });
  });
}
