class CommandParser {
  static Map<String, dynamic> parse(String input, List plants) {
    input = input.toLowerCase();

    // FIND PLANT NAME
    Map<String, dynamic>? matchedPlant;

    for (var plant in plants) {
      if (input.contains(plant['name'].toLowerCase())) {
        matchedPlant = plant;
        break;
      }
    }

    // ADD YIELD
    if (input.contains("yield")) {
      return {
        'action': 'add_yield',
        'plant': matchedPlant,
        'value': _extractNumber(input),
      };
    }

    // WATER / FERTILIZE
    if (input.contains("water") || input.contains("fertilize")) {
      return {
        'action': 'schedule',
        'plant': matchedPlant,
        'type': input.contains("water") ? "watering" : "fertilizing",
        'time': _extractTime(input),
      };
    }

    // ADD PLANT
    if (input.contains("add plant")) {
      return {'action': 'add_plant'};
    }

    return {'action': 'unknown'};
  }

  static int? _extractNumber(String input) {
    final match = RegExp(r'\d+').firstMatch(input);
    return match != null ? int.parse(match.group(0)!) : null;
  }

  static String _extractTime(String input) {
    if (input.contains("morning")) return "08:00";
    if (input.contains("evening")) return "18:00";
    return "12:00";
  }
}