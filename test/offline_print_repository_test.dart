import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/data/print_job_repository.dart';

void main() {
  test('local print repository works without a Firebase app', () async {
    final repository = PrintJobRepository.localOnly();

    expect(
      await repository
          .watchQueuedJobCount(tenantId: 'tenant', venueId: 'venue')
          .first,
      0,
    );
    expect(
      await repository
          .watchVenueJobs(tenantId: 'tenant', venueId: 'venue')
          .first,
      isEmpty,
    );
  });
}
