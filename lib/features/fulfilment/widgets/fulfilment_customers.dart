part of '../fulfilment_management_page.dart';

class _CustomersTab extends ConsumerStatefulWidget {
  const _CustomersTab({required this.scope});
  final VenueScope scope;

  @override
  ConsumerState<_CustomersTab> createState() => _CustomersTabState();
}

class _CustomersTabState extends ConsumerState<_CustomersTab> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final customers = ref.watch(venueCustomersProvider);
    return Scaffold(
      body: customers.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) {
          AppLogger.error('Load venue customers', error, stack);
          return Center(child: Text('Customers could not be loaded: $error'));
        },
        data: (items) {
          final terms = _query.toLowerCase().trim().split(RegExp(r'\s+'));
          final filtered = items.where((item) {
            final value =
                '${item.displayName} ${item.phoneNumbers.join(' ')} ${item.email ?? ''} ${item.addresses.map((address) => '${address.town} ${address.area} ${address.addressLines}').join(' ')}'
                    .toLowerCase();
            return terms.where((term) => term.isNotEmpty).every(value.contains);
          }).toList();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  labelText: 'Search name, phone, email or address',
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
              const SizedBox(height: 12),
              if (filtered.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(
                    child: Text('No matching telephone-order customers.'),
                  ),
                )
              else
                for (final item in filtered)
                  ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: Text(item.displayName),
                    subtitle: Text(
                      '${item.phoneNumbers.join(' · ')} · ${item.claimStatus}${item.addresses.isEmpty ? '' : '\n${item.addresses.map((address) => '${address.label}: ${address.area}, ${address.town}').join(' · ')}'}',
                    ),
                    isThreeLine: item.addresses.isNotEmpty,
                    trailing: IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: 'Edit customer',
                      onPressed: () => showVenueCustomerEditor(
                        context: context,
                        ref: ref,
                        scope: widget.scope,
                        existing: item,
                      ),
                    ),
                  ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showVenueCustomerEditor(
          context: context,
          ref: ref,
          scope: widget.scope,
        ),
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Telephone customer'),
      ),
    );
  }
}
