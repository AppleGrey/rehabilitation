enum ExerciseType { warmup, main, relaxation, strength }

enum ExerciseStatus { pending, inProgress, completed }

class Exercise {
  final String id;
  final String title;
  final ExerciseType type;
  final int durationMinutes;
  final String description;
  final List<String> instructions;
  final List<String> precautions;
  final String? videoUrl;
  final ExerciseStatus status;

  Exercise({
    required this.id,
    required this.title,
    required this.type,
    required this.durationMinutes,
    required this.description,
    this.instructions = const [],
    this.precautions = const [],
    this.videoUrl,
    this.status = ExerciseStatus.pending,
  });

  Exercise copyWith({
    String? id,
    String? title,
    ExerciseType? type,
    int? durationMinutes,
    String? description,
    List<String>? instructions,
    List<String>? precautions,
    String? videoUrl,
    ExerciseStatus? status,
  }) {
    return Exercise(
      id: id ?? this.id,
      title: title ?? this.title,
      type: type ?? this.type,
      durationMinutes: durationMinutes ?? this.durationMinutes,
      description: description ?? this.description,
      instructions: instructions ?? this.instructions,
      precautions: precautions ?? this.precautions,
      videoUrl: videoUrl ?? this.videoUrl,
      status: status ?? this.status,
    );
  }

  String get typeLabel {
    switch (type) {
      case ExerciseType.warmup:
        return '热身';
      case ExerciseType.main:
        return '主训练';
      case ExerciseType.relaxation:
        return '放松';
      case ExerciseType.strength:
        return '强化';
    }
  }
}
