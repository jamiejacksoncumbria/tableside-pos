import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/home_shell.dart';
import '../../core/app_logger.dart';
import '../../core/app_theme_controller.dart';
import '../../core/platform_admin_pin_session_store.dart';
import '../../core/tenant_scope.dart';
import '../../data/auth_repository.dart';
import '../../data/platform_admin_repository.dart';
import '../platform_admin/platform_admin_page.dart';
import '../platform_admin/platform_admin_pin_gate.dart';
import '../pos/domain.dart';
import '../pos/pos_controller.dart';
import 'session_providers.dart';
import 'staff_pin_gate.dart';

class FirebaseAuthGate extends ConsumerWidget {
  const FirebaseAuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<AsyncValue<User?>>(authStateProvider, (previous, next) {
      final previousUid = previous?.asData?.value?.uid;
      final currentUid = next.asData?.value?.uid;
      if (currentUid == null ||
          (previousUid != null && previousUid != currentUid)) {
        AppLogger.info(
          'Firebase authentication changed; clearing local venue and staff sessions.',
        );
        ref.read(activeStaffPinSessionProvider.notifier).lock();
        PlatformAdminPinSessionStore.clear();
        ref.read(activeVenueScopeProvider.notifier).clear();
        ref.read(homeSectionProvider.notifier).select(HomeSection.pos);
      }
    });
    final authState = ref.watch(authStateProvider);
    return authState.when(
      loading: () => const _LoadingScreen(label: 'Checking your session…'),
      error: (error, _) =>
          _ErrorScreen(message: 'Authentication is unavailable: $error'),
      data: (user) => user == null
          ? const SignInPage()
          : AuthenticatedWorkspace(userId: user.uid),
    );
  }
}

class SignInPage extends ConsumerStatefulWidget {
  const SignInPage({super.key});

  @override
  ConsumerState<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends ConsumerState<SignInPage> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _submitting = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    try {
      await ref
          .read(authRepositoryProvider)
          .signIn(email: _email.text.trim(), password: _password.text);
    } on Object catch (error, stackTrace) {
      AppLogger.error('Sign in', error, stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not sign in: $error')));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _resetPassword() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter your email address first.')),
      );
      return;
    }
    try {
      await ref.read(authRepositoryProvider).sendPasswordReset(email);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Password reset email sent.')),
        );
      }
    } on Object catch (error, stackTrace) {
      AppLogger.error('Send password reset email', error, stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send reset email: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.point_of_sale_rounded,
                      color: Theme.of(context).colorScheme.primary,
                      size: 42,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Sign in to TableSide',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.username],
                      decoration: const InputDecoration(
                        labelText: 'Email address',
                      ),
                      validator: (value) =>
                          value == null || !value.contains('@')
                          ? 'Enter a valid email address.'
                          : null,
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _password,
                      obscureText: _obscurePassword,
                      autofillHints: const [AutofillHints.password],
                      onFieldSubmitted: (_) => _signIn(),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        suffixIcon: IconButton(
                          tooltip: _obscurePassword
                              ? 'Show password'
                              : 'Hide password',
                          onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword,
                          ),
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                      validator: (value) => value == null || value.isEmpty
                          ? 'Enter your password.'
                          : null,
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _submitting ? null : _resetPassword,
                        child: const Text('Forgot password?'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: _submitting ? null : _signIn,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: _submitting
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Sign in'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AuthenticatedWorkspace extends ConsumerWidget {
  const AuthenticatedWorkspace({super.key, required this.userId});

  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppLogger.info('Authenticated workspace: checking restaurant memberships.');
    final platformAdmin = ref.watch(platformAdminProvider);
    if (platformAdmin.isLoading) {
      return const _LoadingScreen(label: 'Checking your access…');
    }
    if (platformAdmin.hasError) {
      return const _ErrorScreen(message: 'Could not verify account access.');
    }
    final isPlatformAdmin = platformAdmin.requireValue;
    final memberships = ref.watch(membershipsProvider(userId));
    return memberships.when(
      loading: () => isPlatformAdmin
          ? _PlatformAdminScaffold(
              onSignOut: () => ref.read(authRepositoryProvider).signOut(),
            )
          : const _NoMembershipScreen(checkingMembership: true),
      error: (error, _) =>
          _ErrorScreen(message: 'Could not load restaurant access: $error'),
      data: (items) {
        AppLogger.info(
          'Restaurant access loaded: ${items.length} membership(s).',
        );
        if (items.isEmpty) {
          return isPlatformAdmin
              ? _PlatformAdminScaffold(
                  onSignOut: () => ref.read(authRepositoryProvider).signOut(),
                )
              : const _NoMembershipScreen();
        }
        final scope = ref.watch(activeVenueScopeProvider);
        return scope == null
            ? VenuePicker(memberships: items)
            : _TenantWorkspace(scope: scope);
      },
    );
  }
}

class VenuePicker extends ConsumerStatefulWidget {
  const VenuePicker({super.key, required this.memberships});

  final List<TenantMembership> memberships;

  @override
  ConsumerState<VenuePicker> createState() => _VenuePickerState();
}

class _VenuePickerState extends ConsumerState<VenuePicker> {
  String? _tenantId;

  @override
  Widget build(BuildContext context) {
    final tenantId = _tenantId ?? widget.memberships.first.tenantId;
    final venues = ref.watch(venuesProvider(tenantId));
    final companyNames = <String, String>{
      for (final membership in widget.memberships)
        membership.tenantId: ref
            .watch(liveTenantProfileProvider(membership.tenantId))
            .when(
              data: (profile) => profile.displayName,
              loading: () => 'Loading restaurant…',
              error: (_, _) => 'Restaurant company',
            ),
    };
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Choose a venue',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Your access is restricted to restaurants assigned to your account.',
                  ),
                  const SizedBox(height: 20),
                  DropdownButtonFormField<String>(
                    initialValue: tenantId,
                    decoration: const InputDecoration(
                      labelText: 'Restaurant company',
                    ),
                    items: [
                      for (final membership in widget.memberships)
                        DropdownMenuItem(
                          value: membership.tenantId,
                          child: Text(
                            companyNames[membership.tenantId] ??
                                'Restaurant company',
                          ),
                        ),
                    ],
                    onChanged: (value) => setState(() => _tenantId = value),
                  ),
                  const SizedBox(height: 18),
                  venues.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (error, _) => Text('Could not load venues: $error'),
                    data: (items) => Column(
                      children: [
                        if (items.isEmpty)
                          const Text(
                            'No venues have been assigned to this tenant.',
                          )
                        else
                          for (final venue in items)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: ListTile(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                tileColor: Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                                leading: const Icon(Icons.storefront_outlined),
                                title: Text(venue.name),
                                subtitle: Text(venue.timeZone),
                                trailing: const Icon(
                                  Icons.chevron_right_rounded,
                                ),
                                onTap: () {
                                  AppLogger.info(
                                    'Venue selected: tenant=$tenantId, venue=${venue.id}.',
                                  );
                                  // A scope change must never leave a local
                                  // order pointing at a table from the venue
                                  // just left, even before the POS controller
                                  // rebuilds its live stream.
                                  ref
                                      .read(
                                        activeStaffPinSessionProvider.notifier,
                                      )
                                      .lock();
                                  unawaited(
                                    ref
                                        .read(
                                          appThemeControllerProvider.notifier,
                                        )
                                        .applyVenueDefault(
                                          venue.defaultThemeMode,
                                        ),
                                  );
                                  ref
                                      .read(
                                        activePersistedOrderIdProvider.notifier,
                                      )
                                      .select(null);
                                  ref
                                      .read(selectedTableProvider.notifier)
                                      .select('');
                                  ref
                                      .read(activeVenueScopeProvider.notifier)
                                      .select(
                                        VenueScope(
                                          tenantId: tenantId,
                                          venueId: venue.id,
                                        ),
                                      );
                                },
                              ),
                            ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TenantWorkspace extends ConsumerWidget {
  const _TenantWorkspace({required this.scope});

  final VenueScope scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppLogger.info(
      'Opening venue workspace: tenant=${scope.tenantId}, venue=${scope.venueId}.',
    );
    final profile = ref.watch(liveTenantProfileProvider(scope.tenantId));
    final venues = ref.watch(venuesProvider(scope.tenantId));
    if (profile.isLoading || venues.isLoading) {
      return const _LoadingScreen(label: 'Opening venue…');
    }
    if (profile.hasError || venues.hasError) {
      return _ErrorScreen(message: 'Could not open venue data.');
    }
    final matchingVenues = venues.requireValue.where(
      (item) => item.id == scope.venueId,
    );
    final venue = matchingVenues.isEmpty ? null : matchingVenues.first;
    if (venue == null) {
      AppLogger.error(
        'Open venue workspace',
        StateError(
          'The selected venue is not in the current venue list for this membership.',
        ),
        StackTrace.current,
      );
      return const _ErrorScreen(
        message: 'That venue is no longer available to you.',
      );
    }
    AppLogger.info('Venue workspace ready: ${venue.name}.');
    return StaffPinGate(
      scope: scope,
      backgroundLockSeconds: venue.backgroundLockSeconds,
      onSwitchVenue: () {
        AppLogger.info(
          'Returning to the company and venue picker from PIN screen.',
        );
        ref.read(activeStaffPinSessionProvider.notifier).lock();
        ref.read(homeSectionProvider.notifier).select(HomeSection.pos);
        ref.read(activeVenueScopeProvider.notifier).clear();
      },
      onSignOut: () {
        ref.read(activeStaffPinSessionProvider.notifier).lock();
        ref.read(activeVenueScopeProvider.notifier).clear();
        ref.read(authRepositoryProvider).signOut();
      },
      child: HomeShell(
        profileOverride: profile.requireValue,
        venueOverride: venue,
        persistCompanyProfile: true,
        onSwitchVenue: () {
          AppLogger.info('Returning to the company and venue picker.');
          ref.read(activeStaffPinSessionProvider.notifier).lock();
          ref.read(homeSectionProvider.notifier).select(HomeSection.pos);
          ref.read(activeVenueScopeProvider.notifier).clear();
        },
        onSignOut: () {
          ref.read(activeStaffPinSessionProvider.notifier).lock();
          ref.read(activeVenueScopeProvider.notifier).clear();
          ref.read(authRepositoryProvider).signOut();
        },
      ),
    );
  }
}

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(label),
        ],
      ),
    ),
  );
}

class _ErrorScreen extends StatelessWidget {
  const _ErrorScreen({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(message, textAlign: TextAlign.center),
      ),
    ),
  );
}

class _NoMembershipScreen extends ConsumerStatefulWidget {
  const _NoMembershipScreen({this.checkingMembership = false});

  final bool checkingMembership;

  @override
  ConsumerState<_NoMembershipScreen> createState() =>
      _NoMembershipScreenState();
}

class _NoMembershipScreenState extends ConsumerState<_NoMembershipScreen> {
  bool _claiming = false;

  Future<void> _claimInitialPlatformAdmin() async {
    if (_claiming) return;
    setState(() => _claiming = true);
    try {
      AppLogger.info('Initial platform admin setup: button pressed.');
      final claimAvailable = await ref
          .read(platformAdminRepositoryProvider)
          .bootstrapPlatformAdmin();
      AppLogger.info(
        'Initial platform admin setup: refreshing access state; token claim available=$claimAvailable.',
      );
      ref.invalidate(platformAdminProvider);
      ref.invalidate(authStateProvider);
      if (!claimAvailable && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Your administrator account was created, but Firebase has not refreshed its permissions yet. Please sign out and sign in again.',
            ),
          ),
        );
      }
    } on Object catch (error, stackTrace) {
      AppLogger.error('Bootstrap platform administrator', error, stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not set up platform admin: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _claiming = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.admin_panel_settings_outlined, size: 42),
              const SizedBox(height: 16),
              Text(
                widget.checkingMembership
                    ? 'Checking restaurant access. If this is the first TableSide account, you can set up the platform administrator now.'
                    : 'Your account has no restaurant access yet. Ask an owner to invite you to a tenant and venue.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _claiming ? null : _claimInitialPlatformAdmin,
                icon: const Icon(Icons.verified_user_outlined),
                label: Text(
                  _claiming
                      ? 'Setting up…'
                      : 'Set up the initial platform admin',
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'This succeeds only for the email configured during function deployment.',
                textAlign: TextAlign.center,
              ),
              TextButton(
                onPressed: () => ref.read(authRepositoryProvider).signOut(),
                child: const Text('Sign out'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _PlatformAdminScaffold extends StatelessWidget {
  const _PlatformAdminScaffold({required this.onSignOut});

  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('TableSide platform'),
      actions: [
        IconButton(
          tooltip: 'Sign out',
          onPressed: onSignOut,
          icon: const Icon(Icons.logout_rounded),
        ),
      ],
    ),
    body: const PlatformAdminPinGate(child: PlatformAdminPage()),
  );
}
