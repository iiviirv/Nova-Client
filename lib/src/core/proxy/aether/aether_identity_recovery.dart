import 'dart:io';

import 'package:flutter/foundation.dart';

import 'aether_protocol.dart';

class AetherRecoveryIdentity {
  const AetherRecoveryIdentity(this.handle, this.file);
  final int handle;
  final File file;
}

/// Tests a separate identity after an explicit TLS authorization rejection.
/// A failed experiment must never replace the saved credentials.
class AetherIdentityRecovery {
  static bool _busy = false;
  static const Duration cooldown = Duration(minutes: 5);
  bool _attempted = false;

  Future<AetherJobStatus> recover({
    required AetherJobStatus rejected,
    required File original,
    required Future<AetherRecoveryIdentity> Function(String base) provision,
    required Future<AetherJobStatus> Function(int identity) prove,
    required bool Function() cancelled,
    required void Function(String message) log,
    DateTime Function()? now,
  }) async {
    if (_attempted ||
        _busy ||
        cancelled() ||
        !(rejected.error ?? '').contains('TLSV1_ALERT_ACCESS_DENIED')) {
      return rejected;
    }
    _attempted = true;
    _busy = true;
    Directory? work;
    bool committed = false;
    try {
      final DateTime instant = (now ?? DateTime.now)();
      final File marker = File('${original.path}.recovery-attempt');
      if (await marker.exists()) {
        final int? previous = int.tryParse(await marker.readAsString());
        if (previous != null &&
            instant.millisecondsSinceEpoch - previous <
                cooldown.inMilliseconds) {
          log('identity recovery is cooling down; original identity retained');
          return rejected;
        }
      }
      final List<int> before = await original.readAsBytes();
      if (cancelled()) return rejected;
      await marker.writeAsString('${instant.millisecondsSinceEpoch}',
          flush: true);
      work = await original.parent.createTemp('.aether-recovery-');
      log('TLS authorization rejected; testing a separate MASQUE identity');
      final AetherRecoveryIdentity candidate =
          await provision('${work.path}/identity');
      if (cancelled()) return rejected;
      // Only a newly provisioned file in our scratch directory may be promoted.
      if (candidate.file.parent.absolute.path != work.absolute.path ||
          !await candidate.file.exists()) {
        throw StateError('recovery did not create a separate identity file');
      }
      final AetherJobStatus proof = await prove(candidate.handle);
      if (cancelled()) return rejected;
      // Require explicit end-to-end WARP proof, not merely a completed job.
      if (proof.state != AetherJobState.done ||
          proof.result?['reachable'] != true) {
        log('replacement identity failed verification; original identity retained');
        return proof;
      }
      if (!listEquals(before, await original.readAsBytes())) {
        throw StateError('saved identity changed during recovery');
      }
      // Preserve the exact old file before the atomic replacement. Both files
      // remain in application-private storage and never enter exported logs.
      await original.copy('${work.path}/previous-identity');
      if (cancelled()) return rejected;
      await candidate.file.rename(original.path);
      committed = true;
      log('replacement identity passed WARP proof and was saved; previous identity backed up');
      return proof;
    } catch (_) {
      // Provisioning errors may include account credentials. Keep this message
      // fixed rather than exporting raw API responses or filesystem paths.
      log('identity recovery could not complete; original identity retained');
      return rejected;
    } finally {
      if (!committed && work != null) {
        try {
          await work.delete(recursive: true);
        } catch (_) {
          // A cleanup failure must not hide the original connection failure.
        }
      }
      _busy = false;
    }
  }
}
