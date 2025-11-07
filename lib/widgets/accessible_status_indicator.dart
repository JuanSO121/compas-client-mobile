// lib/widgets/accessible_status_indicator.dart - VERSIÓN MINIMALISTA
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

/// Indicador de estado ultra-simple para accesibilidad
/// Diseño limpio con contraste WCAG AAA
class AccessibleStatusIndicator extends StatelessWidget {
  final String label;
  final bool isActive;
  final String? detailedDescription;

  const AccessibleStatusIndicator({
    Key? key,
    required this.label,
    required this.isActive,
    this.detailedDescription,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final statusText = isActive ? 'activo' : 'inactivo';

    // Colores con alto contraste (WCAG AAA - ratio 7:1)
    final activeColor = isDark ? const Color(0xFF66BB6A) : const Color(0xFF2E7D32);
    final inactiveColor = isDark ? const Color(0xFFEF5350) : const Color(0xFFC62828);
    final bgColor = isDark ? const Color(0xFF2C2C2C) : Colors.white;

    return Semantics(
      label: '$label está $statusText',
      value: statusText,
      readOnly: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: (isActive ? activeColor : inactiveColor).withOpacity(0.4),
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? 0.4 : 0.08),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Indicador circular grande
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isActive ? activeColor : inactiveColor,
                boxShadow: isActive
                    ? [
                  BoxShadow(
                    color: activeColor.withOpacity(0.5),
                    blurRadius: 8,
                    spreadRadius: 2,
                  ),
                ]
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            // Texto grande y legible
            Text(
              label,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : const Color(0xFF212121),
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}