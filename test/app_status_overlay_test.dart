import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/app/pos_app.dart';
import 'package:tableside_pos/core/app_theme_controller.dart';
import 'package:tableside_pos/offline/venue_hub_availability.dart';

void main() {
  test(
    'hub and command status overlays never occupy the same vertical slot',
    () {
      final offsets = appStatusOverlayOffsets(
        topInset: 24,
        showStaging: true,
        showHubIssue: true,
        showPending: true,
      );

      expect(offsets.hubTop, 66);
      expect(offsets.pendingTop, 124);
      expect(offsets.updatesTop, 182);
    },
  );

  test('unused status rows do not reserve screen space', () {
    final offsets = appStatusOverlayOffsets(
      topInset: 0,
      showStaging: false,
      showHubIssue: false,
      showPending: false,
    );

    expect(offsets.hubTop, 8);
    expect(offsets.pendingTop, 8);
    expect(offsets.updatesTop, 8);
  });

  testWidgets('hub recovery closes only its own dialog', (tester) async {
    addTearDown(VenueHubAvailability.markOnline);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appThemeControllerProvider.overrideWith(_TestThemeController.new),
        ],
        child: const TableSideCYApp(),
      ),
    );
    await tester.pumpAndSettle();

    VenueHubAvailability.markOffline('Test hub fault');
    await tester.pumpAndSettle();
    expect(find.text('Venue hub is unavailable'), findsOneWidget);

    final appContext = tester.element(find.byType(Scaffold).first);
    Navigator.of(appContext).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Unrelated payment route')),
      ),
    );
    await tester.pumpAndSettle();

    VenueHubAvailability.markOnline();
    await tester.pumpAndSettle();

    expect(find.text('Unrelated payment route'), findsOneWidget);
    expect(find.text('Venue hub is unavailable'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _TestThemeController extends AppThemeController {
  @override
  AppThemeSelection build() => const AppThemeSelection();
}
