import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/aether/aether_identity_recovery.dart';
import 'package:nova_client/src/core/proxy/aether/aether_protocol.dart';

const denied = AetherJobStatus(AetherJobState.done,
    result: {'reachable': false},
    error: 'masque: await response: [TLSV1_ALERT_ACCESS_DENIED]');
const good = AetherJobStatus(AetherJobState.done, result: {'reachable': true});

void main() {
  late Directory dir;
  late File original;
  late List<String> logs;
  late int provisions;
  late int proofs;
  late bool cancelled;
  late AetherJobStatus result;
  late bool throwProvision;
  late bool changeOriginal;
  late bool cancelAfterProof;
  final DateTime clock = DateTime.utc(2026, 9, 22);

  Future<AetherJobStatus> run(AetherIdentityRecovery recovery,
          {AetherJobStatus rejection = denied, DateTime? at}) =>
      recovery.recover(
        rejected: rejection,
        original: original,
        cancelled: () => cancelled,
        now: () => at ?? clock,
        log: logs.add,
        provision: (String base) async {
          provisions++;
          if (throwProvision) throw StateError('secret-account-token');
          final File candidate = File('$base-masque');
          await candidate.writeAsString('replacement credentials');
          return AetherRecoveryIdentity(42, candidate);
        },
        prove: (int handle) async {
          expect(handle, 42);
          proofs++;
          expect(await original.readAsString(), 'original credentials');
          if (changeOriginal) await original.writeAsString('concurrent update');
          if (cancelAfterProof) cancelled = true;
          return result;
        },
      );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('nova-recovery-test-');
    original = File('${dir.path}/aether-masque');
    await original.writeAsString('original credentials');
    logs = [];
    provisions = proofs = 0;
    cancelled = throwProvision = changeOriginal = cancelAfterProof = false;
    result = good;
  });
  tearDown(() async => dir.delete(recursive: true));

  test('promotes only proven credentials and retains exact original backup',
      () async {
    expect(await run(AetherIdentityRecovery()), same(good));
    expect(await original.readAsString(), 'replacement credentials');
    final List<File> backups = await dir
        .list(recursive: true)
        .where((e) => e.path.endsWith('previous-identity'))
        .cast<File>()
        .toList();
    expect(backups, hasLength(1));
    expect(await backups.single.readAsString(), 'original credentials');
    expect(provisions, 1);
    expect(proofs, 1);
    expect(logs.join(), isNot(contains('credentials')));
  });

  for (final AetherJobStatus failure in [
    denied,
    const AetherJobStatus(AetherJobState.done),
    const AetherJobStatus(AetherJobState.failed, result: {'reachable': true})
  ]) {
    test('does not promote unproven result ${failure.state} ${failure.result}',
        () async {
      result = failure;
      await run(AetherIdentityRecovery());
      expect(await original.readAsString(), 'original credentials');
      expect(await dir.list().where((e) => e is Directory).length, 0);
    });
  }

  test('ordinary timeout never provisions another identity', () async {
    await run(AetherIdentityRecovery(),
        rejection:
            const AetherJobStatus(AetherJobState.failed, error: 'timed out'));
    expect(provisions, 0);
    expect(proofs, 0);
  });

  test('cancel before recovery does no work', () async {
    cancelled = true;
    await run(AetherIdentityRecovery());
    expect(provisions, 0);
  });

  test('cancel after proof preserves original and cleans scratch files',
      () async {
    cancelAfterProof = true;
    await run(AetherIdentityRecovery());
    expect(await original.readAsString(), 'original credentials');
    expect(await dir.list().where((e) => e is Directory).length, 0);
  });

  test('failed registration preserves original and does not log secrets',
      () async {
    throwProvision = true;
    expect(await run(AetherIdentityRecovery()), same(denied));
    expect(await original.readAsString(), 'original credentials');
    expect(logs.join(), isNot(contains('secret-account-token')));
  });

  test('concurrent saved identity change is not overwritten', () async {
    changeOriginal = true;
    await run(AetherIdentityRecovery());
    expect(await original.readAsString(), 'concurrent update');
  });

  test('repeated rejection is limited per search and across fresh searches',
      () async {
    result = denied;
    final recovery = AetherIdentityRecovery();
    await run(recovery);
    await run(recovery, at: clock.add(const Duration(minutes: 6)));
    expect(provisions, 1);
    await run(AetherIdentityRecovery(),
        at: clock.add(const Duration(minutes: 1)));
    expect(provisions, 1);
    await run(AetherIdentityRecovery(),
        at: clock.add(const Duration(minutes: 6)));
    expect(provisions, 2);
  });
}
