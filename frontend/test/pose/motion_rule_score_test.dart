import 'package:flutter_test/flutter_test.dart';
import 'package:rehabilitation_app/pose/follow_models.dart';
import 'package:rehabilitation_app/pose/geometry.dart';

void main() {
  test(
    'live score follows the structured rule and stays hidden without one',
    () {
      expect(motionRuleEnablesLiveScore(null), isFalse);

      final standing = _pose(hip: 0.40, ankle: 0.80);
      final raised = _pose(hip: 0.50, ankle: 0.72, ankleX: 0.66);
      final easy = _rule(pass: 40);
      final strict = _rule(pass: 80);

      expect(motionRuleEnablesLiveScore(easy), isTrue);
      expect(evaluateLocal(standing, easy).metrics['primary'], closeTo(0, 1));
      final raisedScore = evaluateLocal(raised, easy).instantScore;
      final strictScore = evaluateLocal(raised, strict).instantScore;
      expect(raisedScore, greaterThan(40));
      expect(strictScore, lessThan(raisedScore));

      final disabledJson = _ruleJson(pass: 40);
      (disabledJson['metrics'] as List).first['enabled'] = false;
      final disabled = MotionStandard.fromJson(disabledJson);
      expect(motionRuleEnablesLiveScore(disabled), isFalse);
    },
  );
}

MotionStandard _rule({required double pass}) =>
    MotionStandard.fromJson(_ruleJson(pass: pass));

Map<String, dynamic> _ruleJson({required double pass}) => {
  'title_cn': '侧抬腿',
  'min_visibility': 0.45,
  'metrics': [
    {
      'id': 'primary',
      'name_cn': '抬腿角度',
      'enabled': true,
      'weight': 1,
      'definition': {
        'kind': 'segment_to_axis',
        'output': 'degrees_from_down',
        'from': 'right_hip',
        'to': 'right_ankle',
      },
      'pass': {'op': 'gte', 'value': pass},
      'excellent': {'op': 'gte', 'value': pass + 10},
      'reset': {'op': 'lte', 'value': 15},
    },
  ],
  'rep_logic': {
    'required_metric_ids': ['primary'],
    'hold_ms': 300,
  },
};

List<OffsetLandmark> _pose({
  required double hip,
  required double ankle,
  double ankleX = 0.5,
}) {
  final points = List<OffsetLandmark>.filled(
    33,
    const OffsetLandmark(x: 0.5, y: 0.5, v: 0),
  );
  points[24] = OffsetLandmark(x: 0.5, y: hip, v: 1);
  points[28] = OffsetLandmark(x: ankleX, y: ankle, v: 1);
  return points;
}
