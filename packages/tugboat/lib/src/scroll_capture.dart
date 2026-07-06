import 'package:flutter/widgets.dart';

/// Extracts portable scroll metrics for SDK events.
Map<String, Object?> tugboatScrollMetricsData(ScrollMetrics metrics) {
  final data = <String, Object?>{
    'offset': metrics.pixels,
    'axis': metrics.axis.name,
    'minScrollExtent': metrics.minScrollExtent,
    'maxScrollExtent': metrics.maxScrollExtent,
    'viewportDimension': metrics.viewportDimension,
  };
  if (metrics.maxScrollExtent > 0) {
    data['offsetNorm'] = metrics.pixels / metrics.maxScrollExtent;
  }
  if (metrics is PageMetrics) {
    data['page'] = metrics.page;
    data['pageStart'] = metrics.page;
  }
  return data;
}

/// Edge flags from scroll metrics at end of a gesture.
Map<String, Object?> tugboatScrollEdgeData(ScrollMetrics metrics) {
  const epsilon = 0.5;
  final atStart = metrics.extentBefore <= epsilon;
  final atEnd = metrics.extentAfter <= epsilon;
  return {
    'atEdge': atStart || atEnd,
    if (atStart) 'edge': 'start',
    if (atEnd && !atStart) 'edge': 'end',
    if (atStart && atEnd) 'edge': 'both',
    'extentBefore': metrics.extentBefore,
    'extentAfter': metrics.extentAfter,
  };
}

String tugboatSwipeDirection(Offset delta) {
  if (delta.dx.abs() >= delta.dy.abs()) {
    return delta.dx >= 0 ? 'right' : 'left';
  }
  return delta.dy >= 0 ? 'down' : 'up';
}
