import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/core/app_theme_controller.dart';
import 'package:tableside_pos/core/tenant_scope.dart';
import 'package:tableside_pos/features/auth/auth_gate.dart';
import 'package:tableside_pos/offline/venue_hub_offline_workspace.dart';

void main() {
  testWidgets('cached LAN workspace does not mutate providers while mounting', (
    tester,
  ) async {
    final workspace = venueHubOfflineWorkspaceFromSnapshot(
      const VenueScope(tenantId: 'tenant-a', venueId: 'venue-a'),
      const <String, Object?>{
        'tenantName': 'Test Restaurant',
        'venueName': 'Test Venue',
        'currencyCode': 'TRY',
        'defaultThemeMode': 'dark',
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appThemeControllerProvider.overrideWith(_TestThemeController.new),
        ],
        child: MaterialApp(
          home: OfflineHubWorkspace(
            workspace: workspace,
            onRetryOnline: () {},
            autoRecoverOnline: false,
          ),
        ),
      ),
    );

    expect(find.text('Opening saved venue…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _TestThemeController extends AppThemeController {
  @override
  AppThemeSelection build() => const AppThemeSelection();

  @override
  Future<void> applyVenueDefault(String value) async {
    state = state.copyWith(venueDefault: themeModeFromName(value));
  }
}
