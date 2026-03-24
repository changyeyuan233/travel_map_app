import 'package:latlong2/latlong.dart';

import '../models/poi.dart';

class RoutePlanResult {
  const RoutePlanResult({
    required this.orderedPois,
    required this.polyline,
    required this.estimatedMinutes,
  });

  final List<Poi> orderedPois;
  final List<LatLng> polyline;
  final int estimatedMinutes;
}

class RoutePlannerService {
  static const _distance = Distance();
  static const _walkingSpeedKmPerHour = 4.2;

  RoutePlanResult plan({
    required LatLng start,
    required List<Poi> selectedPois,
    required int timeLimitMinutes,
    required TravelPreference preference,
  }) {
    if (selectedPois.isEmpty) {
      return const RoutePlanResult(orderedPois: [], polyline: [], estimatedMinutes: 0);
    }

    final preferred = selectedPois.where((p) => p.category == preference).toList();
    final others = selectedPois.where((p) => p.category != preference).toList();

    final orderedInput = <Poi>[...preferred, ...others];
    final optimized = _nearestNeighbor(start: start, candidates: orderedInput);

    final limited = <Poi>[];
    var current = start;
    var totalMinutes = 0;

    for (final poi in optimized) {
      final legMinutes = _estimateMinutes(current, poi.location);
      if (totalMinutes + legMinutes > timeLimitMinutes) {
        break;
      }
      limited.add(poi);
      totalMinutes += legMinutes;
      current = poi.location;
    }

    return RoutePlanResult(
      orderedPois: limited,
      polyline: [start, ...limited.map((e) => e.location)],
      estimatedMinutes: totalMinutes,
    );
  }

  List<Poi> _nearestNeighbor({
    required LatLng start,
    required List<Poi> candidates,
  }) {
    final remaining = [...candidates];
    final result = <Poi>[];
    var current = start;

    while (remaining.isNotEmpty) {
      remaining.sort(
        (a, b) => _distance
            .as(LengthUnit.Meter, current, a.location)
            .compareTo(_distance.as(LengthUnit.Meter, current, b.location)),
      );
      final next = remaining.removeAt(0);
      result.add(next);
      current = next.location;
    }

    return result;
  }

  int _estimateMinutes(LatLng from, LatLng to) {
    final meters = _distance.as(LengthUnit.Meter, from, to);
    final km = meters / 1000;
    final hours = km / _walkingSpeedKmPerHour;
    return (hours * 60).ceil();
  }
}
