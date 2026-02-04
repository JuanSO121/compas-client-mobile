// lib/models/navigation_models.dart - TIPOS COMUNES
class NavigationIntent {
  final String type, target, suggestedResponse;
  NavigationIntent({required this.type, required this.target, required this.suggestedResponse});
}

class SpatialAnalysis {
  final String description;
  final List<String> obstacles = [];
  final String navigationSuggestion = '';
  SpatialAnalysis(this.description);
}

class ObstacleAlert {
  final bool isCritical; final String direction; final double distance;
  bool get isRecent => true; //
  ObstacleAlert({required this.isCritical, required this.direction, required this.distance});
}
