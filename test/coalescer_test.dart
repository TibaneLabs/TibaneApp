import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/utils/coalescer.dart';

/// Unit tests for the reload coalescer used by BalancesStore — the logic that
/// stops the balance poller's echoed triggers from fanning out redundant
/// fetches.
void main() {
  test('a single run executes the task exactly once', () async {
    var runs = 0;
    final c = Coalescer(() async => runs++);
    await c.run();
    expect(runs, 1);
  });

  test('triggers during an in-flight run collapse into ONE catch-up', () async {
    var runs = 0;
    final gates = <Completer<void>>[];
    final c = Coalescer(() async {
      runs++;
      final gate = Completer<void>();
      gates.add(gate);
      await gate.future;
    });

    // Start run #1 (blocks on its gate).
    final first = c.run();
    expect(runs, 1);
    expect(c.isRunning, isTrue);

    // Three more triggers arrive while #1 is in flight — they must collapse
    // into a single catch-up, not three runs.
    unawaited(c.run());
    unawaited(c.run());
    unawaited(c.run());
    expect(runs, 1); // still only the first has started

    gates[0].complete(); // finish run #1 -> one catch-up (#2) starts
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(runs, 2);

    gates[1].complete(); // finish the catch-up; nothing else queued
    await Future<void>.delayed(Duration.zero);
    expect(runs, 2);
  });

  test('sequential runs each execute (no false coalescing when idle)', () async {
    var runs = 0;
    final c = Coalescer(() async => runs++);
    await c.run();
    await c.run();
    await c.run();
    expect(runs, 3);
  });

  test('cancel() suppresses the catch-up run', () async {
    var runs = 0;
    final gate = Completer<void>();
    var first = true;
    final c = Coalescer(() async {
      runs++;
      if (first) {
        first = false;
        await gate.future;
      }
    });

    final running = c.run(); // #1 blocks
    unawaited(c.run()); // queue a catch-up
    c.cancel(); // ...then cancel it
    gate.complete();
    await running;
    await Future<void>.delayed(Duration.zero);
    expect(runs, 1); // catch-up was suppressed
  });
}
