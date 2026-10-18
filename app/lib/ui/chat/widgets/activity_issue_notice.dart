import 'package:app/domain/session_state.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

import 'activity_presentation.dart';

/// Actionable coordination failures without exposing an internal tool accordion.
class ActivityIssueNotice extends StatelessWidget {
  const ActivityIssueNotice({super.key, required this.tool});

  final ToolEvent tool;

  @override
  Widget build(BuildContext context) {
    final detail = activityIssueDetail(tool);
    final color = tool.status == ToolEventStatus.failed
        ? context.colors.error
        : context.colors.warning;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: AppSpacing.xs,
              children: [
                Text(
                  activityIssueLabel(tool),
                  style: context.typo.sansBody.copyWith(color: color),
                ),
                if (detail != null)
                  Text(
                    detail,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: context.typo.monoSmall.copyWith(
                      color: context.colors.muted,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
