class TrainingRecord {
  final String id;
  final String exerciseId;
  final String exerciseName;
  final DateTime date;
  final int durationMinutes;
  final int completionRate;
  final double deviationAngle;
  final int rating;
  final String? notes;

  TrainingRecord({
    required this.id,
    required this.exerciseId,
    required this.exerciseName,
    required this.date,
    required this.durationMinutes,
    required this.completionRate,
    this.deviationAngle = 0,
    this.rating = 0,
    this.notes,
  });
}

class ProblemAnalysis {
  final String id;
  final String title;
  final String severity;
  final int severityLevel;
  final String description;
  final String suggestion;

  ProblemAnalysis({
    required this.id,
    required this.title,
    required this.severity,
    required this.severityLevel,
    required this.description,
    required this.suggestion,
  });
}
