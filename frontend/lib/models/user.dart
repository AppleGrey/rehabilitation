class User {
  final String id;
  final String name;
  final String phone;
  final String gender;
  final int age;
  final String occupation;
  final List<String> medicalHistory;
  final String? allergyHistory;
  final List<String> rehabilitationAreas;
  final int painLevel;
  final String symptomDescription;

  User({
    required this.id,
    required this.name,
    required this.phone,
    this.gender = '男',
    this.age = 0,
    this.occupation = '',
    this.medicalHistory = const [],
    this.allergyHistory,
    this.rehabilitationAreas = const [],
    this.painLevel = 5,
    this.symptomDescription = '',
  });

  User copyWith({
    String? id,
    String? name,
    String? phone,
    String? gender,
    int? age,
    String? occupation,
    List<String>? medicalHistory,
    String? allergyHistory,
    List<String>? rehabilitationAreas,
    int? painLevel,
    String? symptomDescription,
  }) {
    return User(
      id: id ?? this.id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      gender: gender ?? this.gender,
      age: age ?? this.age,
      occupation: occupation ?? this.occupation,
      medicalHistory: medicalHistory ?? this.medicalHistory,
      allergyHistory: allergyHistory ?? this.allergyHistory,
      rehabilitationAreas: rehabilitationAreas ?? this.rehabilitationAreas,
      painLevel: painLevel ?? this.painLevel,
      symptomDescription: symptomDescription ?? this.symptomDescription,
    );
  }
}
