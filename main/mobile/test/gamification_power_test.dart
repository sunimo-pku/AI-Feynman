import 'package:flutter_test/flutter_test.dart';

int tierScore({required int masteryScore, required int completedRounds, int bountyWins = 0}) {
  return masteryScore * 10 + completedRounds * 5 + bountyWins * 15;
}

void main() {
  test('power formula rewards mastery, rounds and bounty wins', () {
    expect(tierScore(masteryScore: 30, completedRounds: 2, bountyWins: 1), 325);
    expect(tierScore(masteryScore: 0, completedRounds: 0), 0);
  });
}
