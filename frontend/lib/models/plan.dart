import 'exercise.dart';

enum PlanStatus { inProgress, completed, paused }

class RehabilitationPlan {
  final String id;
  final String name;
  final String description;
  final String targetArea;
  final DateTime startDate;
  final DateTime? endDate;
  final int totalDays;
  final int completedDays;
  final int remainingDays;
  final PlanStatus status;
  final List<Exercise> exercises;

  RehabilitationPlan({
    required this.id,
    required this.name,
    required this.description,
    required this.targetArea,
    required this.startDate,
    this.endDate,
    required this.totalDays,
    this.completedDays = 0,
    this.remainingDays = 0,
    this.status = PlanStatus.inProgress,
    this.exercises = const [],
  });

  RehabilitationPlan copyWith({
    String? id,
    String? name,
    String? description,
    String? targetArea,
    DateTime? startDate,
    DateTime? endDate,
    int? totalDays,
    int? completedDays,
    int? remainingDays,
    PlanStatus? status,
    List<Exercise>? exercises,
  }) {
    return RehabilitationPlan(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      targetArea: targetArea ?? this.targetArea,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      totalDays: totalDays ?? this.totalDays,
      completedDays: completedDays ?? this.completedDays,
      remainingDays: remainingDays ?? this.remainingDays,
      status: status ?? this.status,
      exercises: exercises ?? this.exercises,
    );
  }
}
