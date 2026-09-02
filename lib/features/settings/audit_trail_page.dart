import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/date_formats.dart';
import '../../core/tenant_scope.dart';
import '../../data/production_command_repository.dart';
import 'audit_trail_repository.dart';

class AuditTrailPage extends ConsumerStatefulWidget {
  const AuditTrailPage({super.key});

  @override
  ConsumerState<AuditTrailPage> createState() => _AuditTrailPageState();
}

class _AuditTrailPageState extends ConsumerState<AuditTrailPage> {
  final TextEditingController _searchController = TextEditingController();
  Map<String, String> _staffNames = const {};

  @override
  void initState() {
    super.initState();
    _loadStaffNames();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadStaffNames() async {
    final scope = ref.read(activeVenueScopeProvider);
    if (scope == null) return;
    try {
      final staff = await ref
          .read(productionCommandRepositoryProvider)
          .listVenuePinStaff(scope);
      if (!mounted) return;
      setState(() {
        _staffNames = {
          for (final member in staff) member.userId: member.displayName,
        };
      });
    } on Object catch (error, stackTrace) {
      AppLogger.error('Load audit actor names', error, stackTrace);
    }
  }

  Future<void> _refresh() async {
    ref.invalidate(auditTrailProvider);
    await _loadStaffNames();
  }

  @override
  Widget build(BuildContext context) {
    final audit = ref.watch(auditTrailProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Audit trail'),
        actions: [
          IconButton(
            tooltip: 'Refresh audit trail',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Search actions, staff or references',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        onPressed: () {
                          _searchController.clear();
                          setState(() {});
                        },
                        icon: const Icon(Icons.clear_rounded),
                      ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Icon(Icons.lock_outline_rounded, size: 17),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Read-only history. Audit records cannot be edited or deleted from the app.',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: audit.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stackTrace) {
                AppLogger.error('Display audit trail', error, stackTrace);
                return _AuditError(error: error, onRetry: _refresh);
              },
              data: (events) {
                final visible = _filtered(events);
                if (visible.isEmpty) {
                  return RefreshIndicator(
                    onRefresh: _refresh,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        const SizedBox(height: 100),
                        Icon(
                          _searchController.text.trim().isEmpty
                              ? Icons.history_rounded
                              : Icons.search_off_rounded,
                          size: 52,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _searchController.text.trim().isEmpty
                              ? 'No audit events have been recorded yet.'
                              : 'No audit events match this search.',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  );
                }
                return RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                    itemCount: visible.length,
                    itemBuilder: (context, index) => _AuditEventCard(
                      event: visible[index],
                      actorName: _actorName(visible[index]),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  List<AuditTrailEvent> _filtered(List<AuditTrailEvent> events) {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return events;
    return events
        .where((event) {
          final text = [
            event.action,
            _humanizeAction(event.action),
            _actorName(event),
            event.actorUserId,
            event.venueId,
            event.target,
            for (final entry in event.details.entries) entry.key,
            for (final entry in event.details.entries)
              _formatValue(entry.value),
          ].whereType<String>().join(' ').toLowerCase();
          return text.contains(query);
        })
        .toList(growable: false);
  }

  String _actorName(AuditTrailEvent event) {
    final id = event.actorUserId;
    if (id == null) return 'System';
    return _staffNames[id] ?? 'Former/unknown staff';
  }
}

class _AuditEventCard extends StatelessWidget {
  const _AuditEventCard({required this.event, required this.actorName});

  final AuditTrailEvent event;
  final String actorName;

  @override
  Widget build(BuildContext context) {
    final entries =
        event.details.entries
            .where((entry) => !_sensitiveKey(entry.key))
            .toList(growable: false)
          ..sort((a, b) => a.key.compareTo(b.key));
    return Card(
      child: ExpansionTile(
        leading: const CircleAvatar(child: Icon(Icons.history_rounded)),
        title: Text(_humanizeAction(event.action)),
        subtitle: Wrap(
          spacing: 12,
          runSpacing: 3,
          children: [
            Text(
              event.createdAt == null
                  ? 'Time pending'
                  : formatAppDateTime(event.createdAt!),
            ),
            Text('By $actorName'),
            if (event.venueId != null) Text('Venue ${event.venueId}'),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          const Divider(),
          if (event.actorUserId != null)
            _AuditDetail(label: 'Actor ID', value: event.actorUserId!),
          if (event.target != null)
            _AuditDetail(label: 'Target', value: event.target!),
          _AuditDetail(label: 'Event ID', value: event.id),
          for (final entry in entries)
            _AuditDetail(
              label: _humanizeAction(entry.key),
              value: _formatValue(entry.value),
            ),
        ],
      ),
    );
  }
}

class _AuditDetail extends StatelessWidget {
  const _AuditDetail({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 7),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: Text(label, style: Theme.of(context).textTheme.labelMedium),
        ),
        const SizedBox(width: 10),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );
}

class _AuditError extends StatelessWidget {
  const _AuditError({required this.error, required this.onRetry});

  final Object error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const Icon(Icons.error_outline_rounded, size: 52),
      const SizedBox(height: 12),
      Text(
        'The audit trail could not be loaded.\n$error',
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 12),
      Center(
        child: FilledButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Try again'),
        ),
      ),
    ],
  );
}

String _humanizeAction(String value) {
  final spaced = value
      .replaceAll(RegExp(r'[_-]+'), ' ')
      .replaceAllMapped(
        RegExp(r'([a-z0-9])([A-Z])'),
        (match) => '${match.group(1)} ${match.group(2)}',
      )
      .trim();
  if (spaced.isEmpty) return 'Unknown action';
  return '${spaced[0].toUpperCase()}${spaced.substring(1)}';
}

bool _sensitiveKey(String key) {
  final normalized = key.toLowerCase();
  return normalized.contains('password') ||
      normalized.contains('pinhash') ||
      normalized.contains('token') ||
      normalized.contains('credential') ||
      normalized == 'salt';
}

String _formatValue(Object? value) {
  if (value == null) return '—';
  if (value is Timestamp) return formatAppDateTime(value.toDate());
  if (value is DateTime) return formatAppDateTime(value);
  if (value is Iterable) {
    return value.map(_formatValue).join(', ');
  }
  if (value is Map) {
    final entries = value.entries
        .where((entry) => !_sensitiveKey('${entry.key}'))
        .map((entry) => '${entry.key}: ${_formatValue(entry.value)}');
    return entries.join(', ');
  }
  return '$value';
}
