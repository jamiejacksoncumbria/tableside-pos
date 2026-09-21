enum TableSideEnvironment { staging, production }

abstract final class AppEnvironment {
  static const _configuredName = String.fromEnvironment(
    'TABLESIDE_ENVIRONMENT',
    defaultValue: 'staging',
  );

  static TableSideEnvironment get current {
    switch (_configuredName.toLowerCase()) {
      case 'staging':
        return TableSideEnvironment.staging;
      case 'production':
        return TableSideEnvironment.production;
      default:
        throw StateError(
          'TABLESIDE_ENVIRONMENT must be either staging or production.',
        );
    }
  }

  static bool get isStaging => current == TableSideEnvironment.staging;
  static bool get isProduction => current == TableSideEnvironment.production;
  static String get label => isProduction ? 'PRODUCTION' : 'STAGING';
}
