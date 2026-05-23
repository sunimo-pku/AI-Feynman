class CurriculumKnowledgePoint {
  const CurriculumKnowledgePoint({
    required this.id,
    required this.title,
    required this.label,
    this.order = 0,
  });

  final String id;
  final String title;
  final String label;
  final int order;

  factory CurriculumKnowledgePoint.fromJson(Map<String, dynamic> json) {
    return CurriculumKnowledgePoint(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      label: json['label'] as String? ?? json['title'] as String? ?? '',
      order: (json['order'] as num?)?.toInt() ?? 0,
    );
  }
}

class CurriculumSection {
  const CurriculumSection({
    required this.id,
    required this.number,
    required this.title,
    required this.label,
    required this.type,
    required this.contentStatus,
    this.v1Launch = false,
    this.knowledgePoints = const [],
  });

  final String id;
  final String number;
  final String title;
  final String label;
  final String type;
  final String contentStatus;
  final bool v1Launch;
  final List<CurriculumKnowledgePoint> knowledgePoints;

  bool get isAvailable => contentStatus == 'available';

  int get knowledgePointCount => knowledgePoints.length;

  factory CurriculumSection.fromJson(Map<String, dynamic> json) {
    final rawKps = json['knowledgePoints'];
    final kps =
        rawKps is List
            ? rawKps
                .whereType<Map<String, dynamic>>()
                .map(CurriculumKnowledgePoint.fromJson)
                .where((kp) => kp.id.isNotEmpty)
                .toList(growable: false)
            : const <CurriculumKnowledgePoint>[];
    return CurriculumSection(
      id: json['id'] as String,
      number: json['number'] as String,
      title: json['title'] as String,
      label: json['label'] as String,
      type: json['type'] as String,
      contentStatus: json['contentStatus'] as String? ?? 'coming_soon',
      v1Launch: json['v1Launch'] as bool? ?? false,
      knowledgePoints: kps,
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
    required this.semester,
    required this.semesterLabel,
    required this.label,
    required this.chapters,
    this.bookType = '',
  });

  final String id;
  final String gradeLabel;
  final int semester;
  final String semesterLabel;
  final String label;
  final List<CurriculumChapter> chapters;
  final String bookType;

  bool get isExamSprint => bookType == 'exam_sprint' || id.contains('sprint');

  factory CurriculumBook.fromJson(Map<String, dynamic> json) {
    return CurriculumBook(
      id: json['id'] as String,
      gradeLabel: json['gradeLabel'] as String,
      semester: (json['semester'] as num?)?.toInt() ?? 0,
      semesterLabel: json['semesterLabel'] as String,
      label: json['label'] as String,
      bookType: json['bookType'] as String? ?? '',
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
