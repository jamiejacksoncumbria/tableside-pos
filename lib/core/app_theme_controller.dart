import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';

const _cachedVenueThemeKey = 'tableside.cachedVenueThemeMode';

final appThemeControllerProvider =
    NotifierProvider<AppThemeController, AppThemeSelection>(
      AppThemeController.new,
    );

class AppThemeSelection {
  const AppThemeSelection({
    this.venueDefault = ThemeMode.light,
    this.userPreference,
  });

  final ThemeMode venueDefault;
  final ThemeMode? userPreference;

  ThemeMode get effectiveMode => userPreference ?? venueDefault;

  AppThemeSelection copyWith({
    ThemeMode? venueDefault,
    ThemeMode? userPreference,
    bool clearUserPreference = false,
  }) => AppThemeSelection(
    venueDefault: venueDefault ?? this.venueDefault,
    userPreference: clearUserPreference
        ? null
        : userPreference ?? this.userPreference,
  );
}

class AppThemeController extends Notifier<AppThemeSelection> {
  int _venueRevision = 0;

  @override
  AppThemeSelection build() {
    unawaited(_restoreCachedVenueDefault());
    return const AppThemeSelection();
  }

  Future<void> _restoreCachedVenueDefault() async {
    final revision = _venueRevision;
    try {
      final stored = await SharedPreferencesAsync().getString(
        _cachedVenueThemeKey,
      );
      if (stored == null ||
          state.userPreference != null ||
          revision != _venueRevision) {
        return;
      }
      state = state.copyWith(venueDefault: themeModeFromName(stored));
    } on Object catch (error, stackTrace) {
      AppLogger.error('Restore cached venue theme', error, stackTrace);
    }
  }

  Future<void> applyVenueDefault(String value) async {
    _venueRevision += 1;
    final mode = themeModeFromName(value);
    if (state.venueDefault != mode) {
      state = state.copyWith(venueDefault: mode);
    }
    try {
      await SharedPreferencesAsync().setString(
        _cachedVenueThemeKey,
        themeModeName(mode),
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Cache venue theme', error, stackTrace);
    }
  }

  void applyUserPreference(String? value) {
    if (value == null || value == 'venue') {
      state = state.copyWith(clearUserPreference: true);
      return;
    }
    state = state.copyWith(userPreference: themeModeFromName(value));
  }

  void clearUserPreference() {
    if (state.userPreference != null) {
      state = state.copyWith(clearUserPreference: true);
    }
  }
}

ThemeMode themeModeFromName(String? value) => switch (value) {
  'dark' => ThemeMode.dark,
  _ => ThemeMode.light,
};

String themeModeName(ThemeMode mode) =>
    mode == ThemeMode.dark ? 'dark' : 'light';
