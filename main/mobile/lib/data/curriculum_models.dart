class CurriculumSection {
  const CurriculumSection({
    required this.id,
    required this.number,
    required this.title,
    required this.label,
    required this.type,
    required this.contentStatus,
    this.v1Launch = false,
  });

  final String id;
  final String number;
  final String title;
  final String label;
  final String type;
  final String contentStatus;
  final bool v1Launch;

  bool get isAvailable => contentStatus == 'available';

  factory CurriculumSection.fromJson(Map<String, dynamic> json) {
    return CurriculumSection(
      id: json['id'] as String,
      number: json['number'] as String,
      title: json['title'] as String,
      label: json['label'] as String,
      type: json['type'] as String,
      contentStatus: json['contentStatus'] as String? ?? 'coming_soon',
      v1Launch: json['v1Launch'] as bool? ?? false,
    );
  }
}

class CurriculumChapter {
  const CurriculumChapter({
    required this.id,
    required this.number,
    required this.title,
    required this.label,
    required this.sections,
  });

  final String id;
  final int number;
  final String title;
  final String label;
  final List<CurriculumSection> sections;

  factory CurriculumChapter.fromJson(Map<String, dynamic> json) {
    return CurriculumChapter(
      id: json['id'] as String,
      number: json['number'] as int,
      title: json['title'] as String,
      label: json['label'] as String,
      sections: (json['sections'] as List<dynamic>)
          .map((e) => CurriculumSection.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class CurriculumBook {
  const CurriculumBook({
    required this.id,
    required this.gradeLabel,
    required this.semesterLabel,
    required this.label,
    required this.chapters,
  });

  final String id;
  final String gradeLabel;
  final String semesterLabel;
  final String label;
  final List<CurriculumChapter> chapters;

  factory CurriculumBook.fromJson(Map<String, dynamic> json) {
    return CurriculumBook(
      id: json['id'] as String,
      gradeLabel: json['gradeLabel'] as String,
      semesterLabel: json['semesterLabel'] as String,
      label: json['label'] as String,
      chapters: (json['chapters'] as List<dynamic>)
          .map((e) => CurriculumChapter.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class MathCurriculum {
  const MathCurriculum({
    required this.subjectLabel,
    required this.stageLabel,
    required this.publisher,
    required this.books,
  });

  final String subjectLabel;
  final String stageLabel;
  final String publisher;
  final List<CurriculumBook> books;

  factory MathCurriculum.fromJson(Map<String, dynamic> json) {
    return MathCurriculum(
      subjectLabel: json['subjectLabel'] as String,
      stageLabel: json['stageLabel'] as String,
      publisher: json['publisher'] as String,
      books: (json['books'] as List<dynamic>)
          .map((e) => CurriculumBook.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
