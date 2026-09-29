import 'package:flutter/material.dart';

// ─────────────────────────────────────────────────────────────────────────────
// GROWTH STAGES  —  shared utility
// Mirrors the pattern established in schedule_colors.dart.
//
// Adding a new stage requires changes in ONE place only: this file.
//   • Add the stage key string to [growthStageOrder] (controls display order)
//   • Add entries in getGrowthStageColor(), getGrowthStageIcon(),
//     getGrowthStageLabel(), and getGrowthStageEmoji()
// ─────────────────────────────────────────────────────────────────────────────

/// Canonical ordered list of all stage keys.
/// This order is used for the horizontal chip selector in the UI.
const List<String> growthStageOrder = [
  'seedling',
  'germinating',
  'vegetative',
  'flowering',
  'fruiting',
  'ripening',
  'dormant',
];

// ─────────────────────────────────────────────
// COLOR
// ─────────────────────────────────────────────
Color getGrowthStageColor(String? stage) {
  switch (stage?.toLowerCase().trim()) {
    case 'seedling':
      return const Color(0xFF81C784); // light green
    case 'germinating':
      return const Color(0xFF4CAF50); // medium green
    case 'vegetative':
      return const Color(0xFF388E3C); // dark green
    case 'flowering':
      return const Color(0xFFEC407A); // pink
    case 'fruiting':
      return const Color(0xFFFF7043); // deep orange
    case 'ripening':
      return const Color(0xFFFFA726); // amber orange
    case 'dormant':
      return const Color(0xFF90A4AE); // blue grey
    default:
      return const Color(0xFF9E9E9E); // neutral grey — no stage set
  }
}

// ─────────────────────────────────────────────
// ICON
// ─────────────────────────────────────────────
IconData getGrowthStageIcon(String? stage) {
  switch (stage?.toLowerCase().trim()) {
    case 'seedling':
      return Icons.grass;
    case 'germinating':
      return Icons.spa;
    case 'vegetative':
      return Icons.eco;
    case 'flowering':
      return Icons.local_florist;
    case 'fruiting':
      return Icons.agriculture;
    case 'ripening':
      return Icons.wb_sunny;
    case 'dormant':
      return Icons.nights_stay;
    default:
      return Icons.help_outline;
  }
}

// ─────────────────────────────────────────────
// LABEL  (plain readable text)
// ─────────────────────────────────────────────
String getGrowthStageLabel(String? stage) {
  switch (stage?.toLowerCase().trim()) {
    case 'seedling':
      return 'Seedling';
    case 'germinating':
      return 'Germinating';
    case 'vegetative':
      return 'Vegetative';
    case 'flowering':
      return 'Flowering';
    case 'fruiting':
      return 'Fruiting';
    case 'ripening':
      return 'Ripening';
    case 'dormant':
      return 'Dormant';
    default:
      return 'No Stage Set';
  }
}

// ─────────────────────────────────────────────
// EMOJI  (for compact display on plant cards)
// ─────────────────────────────────────────────
String getGrowthStageEmoji(String? stage) {
  switch (stage?.toLowerCase().trim()) {
    case 'seedling':
      return '🌱';
    case 'germinating':
      return '🌿';
    case 'vegetative':
      return '🍃';
    case 'flowering':
      return '🌸';
    case 'fruiting':
      return '🍅';
    case 'ripening':
      return '🌕';
    case 'dormant':
      return '💤';
    default:
      return '❓';
  }
}

// ─────────────────────────────────────────────
// BADGE WIDGET
// A self-contained chip used on plant cards.
// Pass [compact: true] for a minimal icon-only badge.
// ─────────────────────────────────────────────
class GrowthStageBadge extends StatelessWidget {
  final String? stage;
  final bool compact;

  const GrowthStageBadge({
    super.key,
    required this.stage,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final hasStage = stage != null && stage!.trim().isNotEmpty;

    // Don't render anything if no stage set and in compact mode
    if (!hasStage && compact) return const SizedBox.shrink();

    final color  = getGrowthStageColor(stage);
    final label  = getGrowthStageLabel(stage);
    final icon   = getGrowthStageIcon(stage);

    if (compact) {
      // Small coloured circle with icon — sits in plant card corner
      return Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 1.5),
        ),
        child: Icon(icon, size: 14, color: color),
      );
    }

    // Full chip — used in detail / edit screens
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.5), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// STAGE SELECTOR WIDGET
// Horizontal scrollable chip row.
// Selected chip is filled; others are outlined.
// Pass [allowClear: true] to show a ✕ "None" option at the start.
// ─────────────────────────────────────────────
class GrowthStageSelector extends StatelessWidget {
  final String? selectedStage;
  final ValueChanged<String?> onStageSelected;
  final bool allowClear;

  const GrowthStageSelector({
    super.key,
    required this.selectedStage,
    required this.onStageSelected,
    this.allowClear = true,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          // ── Optional "Clear / None" chip ──
          if (allowClear) ...[
            _ClearChip(
              isSelected: selectedStage == null || selectedStage!.isEmpty,
              onTap: () => onStageSelected(null),
            ),
            const SizedBox(width: 8),
          ],

          // ── Stage chips ──
          ...growthStageOrder.map((stage) {
            final isSelected = selectedStage == stage;
            final color      = getGrowthStageColor(stage);
            final icon       = getGrowthStageIcon(stage);
            final label      = getGrowthStageLabel(stage);

            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () => onStageSelected(isSelected ? null : stage),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: isSelected ? color : color.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isSelected
                          ? color
                          : color.withOpacity(0.4),
                      width: isSelected ? 1.5 : 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        icon,
                        size: 15,
                        color: isSelected ? Colors.white : color,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isSelected ? Colors.white : color,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

// ─── Internal helper chip for the "None" / clear option ───
class _ClearChip extends StatelessWidget {
  final bool isSelected;
  final VoidCallback onTap;

  const _ClearChip({required this.isSelected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFF9E9E9E);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected ? color : color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? color : color.withOpacity(0.4),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.block,
              size: 14,
              color: isSelected ? Colors.white : color,
            ),
            const SizedBox(width: 5),
            Text(
              'None',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isSelected ? Colors.white : color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}