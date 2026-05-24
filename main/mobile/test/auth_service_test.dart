import 'dart:convert';

import 'package:ai_feynman/data/review_models.dart';
import 'package:ai_feynman/services/auth_service.dart';
import 'package:ai_feynman/services/knowledge_point_progress_repository.dart';
import 'package:ai_feynman/services/progress_repository.dart';
import 'package:ai_feynman/services/review_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String jwtWithExp(int expSeconds, {String role = 'student'}) {
    String encodePart(Map<String, dynamic> value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    return '${encodePart({'alg': 'HS256', 'typ': 'JWT'})}.'
        '${encodePart({'sub': 'student-a', 'role': role, 'exp': expSeconds})}.sig';
  }

  group('AuthService persistence', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      AuthService.instance.testPrefsOverride =
          await SharedPreferences.getInstance();
      AuthService.instance.resetCacheOnlyForTesting();
      await AuthService.instance.logout();
    });

    test('load yields logged out when prefs empty', () async {
      await AuthService.instance.load();
      expect(AuthService.instance.isLoggedIn, false);
      expect(AuthService.instance.currentToken, '');
    });

    test('authHeaders does not include Bearer when logged out', () {
      final headers = AuthService.instance.authHeaders();
      expect(headers.containsKey('Authorization'), false);
      expect(headers['Content-Type'], 'application/json; charset=utf-8');
    });

    test('storage namespace uses collision-free encoded username', () {
      final slash = AuthService.storageNamespaceForTesting('a/b');
      final underscore = AuthService.storageNamespaceForTesting('a_b');
      expect(slash, isNot(underscore));
      expect(slash, startsWith('u_'));
      expect(underscore, startsWith('u_'));
    });

    test('load clears expired persisted token', () async {
      final prefs = AuthService.instance.testPrefsOverride!;
      await prefs.setString('ai_feynman.auth.token.v1', jwtWithExp(1));
      await prefs.setString('ai_feynman.auth.username.v1', 'student-a');
      await prefs.setString('ai_feynman.auth.role.v1', 'student');
      AuthService.instance.resetCacheOnlyForTesting();

      await AuthService.instance.load();

      expect(AuthService.instance.isLoggedIn, false);
      expect(prefs.getString('ai_feynman.auth.token.v1'), isNull);
      expect(prefs.getString('ai_feynman.auth.username.v1'), isNull);
      expect(prefs.getString('ai_feynman.auth.role.v1'), isNull);
    });

    test(
      'logout clears active learning caches without deleting stored namespaces',
      () async {
        final prefs = AuthService.instance.testPrefsOverride!;
        ProgressRepository.instance.testPrefsOverride = prefs;
        ReviewRepository.instance.testPrefsOverride = prefs;
        KnowledgePointProgressRepository.instance.testPrefsOverride = prefs;
        await ProgressRepository.instance.switchUser('logout-user');
        await ReviewRepository.instance.switchUser('logout-user');
        await KnowledgePointProgressRepository.instance.switchUser(
          'logout-user',
        );
        await ProgressRepository.instance.applyCompleted(
          sectionId: 'pep-g8-down-s16-3',
          masteryDelta: 1,
          summary: 'done',
        );
        await ReviewRepository.instance.append(
          LectureReviewRecord(
            id: 'review-1',
            sectionId: 'pep-g8-down-s16-3',
            questionId: 'q1',
            questionPrompt: 'p',
            difficulty: 1,
            tags: const [],
            completedAt: DateTime(2026, 5, 22),
            summary: 'summary',
            agentHighlights: const [],
            cautionPoints: const [],
          ),
        );
        await KnowledgePointProgressRepository.instance.applyRound(
          knowledgePointId: 'kp-1',
          status: 'completed',
          masteryDelta: 1,
          peersUnderstood: 3,
        );

        await AuthService.instance.logout();

        expect(
          ProgressRepository.instance
              .progressFor('pep-g8-down-s16-3')
              .masteryScore,
          0,
        );
        expect(
          ReviewRepository.instance.recordsForSection('pep-g8-down-s16-3'),
          isEmpty,
        );
        expect(
          KnowledgePointProgressRepository.instance.progressFor('kp-1').stars,
          0,
        );
        expect(
          prefs.getString('ai_feynman.section_progress.v1.logout-user'),
          isNotNull,
        );
      },
    );
  });
}
