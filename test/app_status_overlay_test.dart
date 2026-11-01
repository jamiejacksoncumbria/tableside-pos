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
        showHubIssue: true,
        showPending: true,
      );

      expect(offsets.hubTop, 32);
      expect(offsets.pendingTop, 90);
      expect(offsets.updatesTop, 148);
    },
  );

  test('unused status rows do not reserve screen space', () {
    final offsets = appStatusOverlayOffsets(
      topInset: 0,
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

  testWidgets(
    'compact hub status uses a reserved strip below app bar actions',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(VenueHubAvailability.reset);
      VenueHubAvailability.markOnline();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appThemeControllerProvider.overrideWith(_TestThemeController.new),
          ],
          child: const TableSideCYApp(),
        ),
      );
      await tester.pumpAndSettle();
      // The compact menu intentionally hides the complete shell. Selecting the
      // Tables tab restores the app bar and its reserved connection strip.
      await tester.tap(find.byType(Tab).first);
      await tester.pumpAndSettle();

      final statusLabel = find.text('Hub + internet online');
      expect(statusLabel, findsOneWidget);
      expect(
        find.ancestor(of: statusLabel, matching: find.byType(Positioned)),
        findsNothing,
      );
      final strip = tester.widget<SizedBox>(
        find.ancestor(of: statusLabel, matching: find.byType(SizedBox)).first,
      );
      expect(strip.height, 18);
      expect(tester.takeException(), isNull);
    },
  );
}

class _TestThemeController extends AppThemeController {
  @override
  AppThemeSelection build() => const AppThemeSelection();
}
