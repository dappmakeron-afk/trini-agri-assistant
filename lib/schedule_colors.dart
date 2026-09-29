// utils/schedule_colors.dart
import 'package:flutter/material.dart';

/// Returns the display colour for a given schedule type.
/// Covers all types defined in schedule_screen.dart.
Color getScheduleColor(String? type) {
  switch (type) {
    case 'water':
      return Colors.blue;
    case 'fertilize':
      return Colors.green;
    case 'appearance':
      return Colors.orange;
    case 'trim':
      return Colors.teal;
    case 'pest':
      return Colors.red;
    case 'disease':
      return Colors.purple;
    case 'repot':
      return Colors.brown;
    case 'mulch':
      return Colors.amber.shade700;
    default:
      return Colors.grey;
  }
}

/// Returns the icon for a given schedule type.
IconData getScheduleIcon(String? type) {
  switch (type) {
    case 'water':
      return Icons.water_drop;
    case 'fertilize':
      return Icons.eco;
    case 'appearance':
      return Icons.visibility;
    case 'trim':
      return Icons.content_cut;
    case 'pest':
      return Icons.bug_report;
    case 'disease':
      return Icons.coronavirus;
    case 'repot':
      return Icons.yard;
    case 'mulch':
      return Icons.grass;
    default:
      return Icons.event;
  }
}

/// Returns a human-readable label for a given schedule type.
/// Used anywhere a raw DB value needs to be displayed to the user.
String getScheduleLabel(String? type) {
  switch (type) {
    case 'water':
      return 'Water';
    case 'fertilize':
      return 'Fertilize';
    case 'appearance':
      return 'Appearance Check';
    case 'trim':
      return 'Trimming / Pruning';
    case 'pest':
      return 'Pest Control';
    case 'disease':
      return 'Disease Treatment';
    case 'repot':
      return 'Repotting';
    case 'mulch':
      return 'Mulching';
    default:
      return type ?? 'Unknown';
  }
}