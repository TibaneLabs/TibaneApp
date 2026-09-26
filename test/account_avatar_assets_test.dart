import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/services/wallet/account_avatar_assets.dart';

void main() {
  group('account avatar assignments', () {
    test('assigns unique assets while the avatar pool has room', () {
      final assigned = ensureAccountAvatarAssignments(
        accountIds: const ['sol', 'eth', 'btc'],
        existingAssignments: const {},
        random: math.Random(7),
      );

      expect(assigned.keys, containsAll(const ['sol', 'eth', 'btc']));
      expect(assigned.values.toSet(), hasLength(3));
      expect(assigned.values.every(kAccountAvatarAssets.contains), isTrue);
    });

    test('keeps valid existing assignments', () {
      final assigned = ensureAccountAvatarAssignments(
        accountIds: const ['sol', 'eth'],
        existingAssignments: const {
          'sol': 'assets/account_pfps/account_pfp_01.png',
        },
        random: math.Random(1),
      );

      expect(assigned['sol'], 'assets/account_pfps/account_pfp_01.png');
      expect(assigned['eth'], isNotNull);
      expect(assigned['eth'], isNot(assigned['sol']));
    });

    test('preserves assignments for ids absent from the current list', () {
      // A transiently-partial account list (only 'sol' present) must NOT drop
      // the stored choice for 'eth' — verify-before-delete (F3).
      final assigned = ensureAccountAvatarAssignments(
        accountIds: const ['sol'],
        existingAssignments: const {
          'sol': 'assets/account_pfps/account_pfp_01.png',
          'eth': 'assets/account_pfps/account_pfp_02.png',
        },
        random: math.Random(1),
      );

      expect(assigned['sol'], 'assets/account_pfps/account_pfp_01.png');
      expect(assigned['eth'], 'assets/account_pfps/account_pfp_02.png');
    });

    test('drops an existing assignment whose asset is no longer valid', () {
      final assigned = ensureAccountAvatarAssignments(
        accountIds: const ['sol'],
        existingAssignments: const {'sol': 'assets/account_pfps/gone.png'},
        random: math.Random(1),
      );

      // The stale asset is replaced with a valid one for the still-present id.
      expect(assigned['sol'], isNot('assets/account_pfps/gone.png'));
      expect(kAccountAvatarAssets.contains(assigned['sol']), isTrue);
    });
  });
}
