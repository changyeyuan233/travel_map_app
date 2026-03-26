import 'package:latlong2/latlong.dart';

import '../models/poi.dart';

enum TravelMode {
  walk,
  bike,
  transit,
  drive,
}

class RouteLeg {
  const RouteLeg({
    required this.from,
    required this.to,
    required this.mode,
    required this.distanceMeters,
    required this.estimatedMinutes,
  });

  final LatLng from;
  final LatLng to;
  final TravelMode mode;
  final int distanceMeters;
  final int estimatedMinutes;
}

class RoutePlanResult {
  const RoutePlanResult({
    required this.orderedPois,
    required this.polyline,
    required this.legs,
    required this.estimatedMinutes,
  });

  final List<Poi> orderedPois;
  final List<LatLng> polyline;
  final List<RouteLeg> legs;
  final int estimatedMinutes;
}

class RoutePlannerService {
  static const _distance = Distance();
  static const _walkingSpeedKmPerHour = 4.2;
  static const _bikeSpeedKmPerHour = 13.0;
  static const _transitSpeedKmPerHour = 22.0;
  static const _driveSpeedKmPerHour = 35.0;

  RoutePlanResult plan({
    required LatLng start,
    required List<Poi> selectedPois,
    required int timeLimitMinutes,
    required TravelPreference preference,
  }) {
    if (selectedPois.isEmpty) {
      return const RoutePlanResult(orderedPois: [], polyline: [], legs: [], estimatedMinutes: 0);
    }

    final preferred = selectedPois.where((p) => p.category == preference).toList();
    final others = selectedPois.where((p) => p.category != preference).toList();

    final orderedInput = <Poi>[...preferred, ...others];
    final optimized = _nearestNeighbor(start: start, candidates: orderedInput);

    final limited = <Poi>[];
    var current = start;
    var totalMinutes = 0;

    for (final poi in optimized) {
      final leg = _estimateLeg(current, poi.location);
      final legMinutes = leg.estimatedMinutes;
      if (totalMinutes + legMinutes > timeLimitMinutes) {
        break;
      }
      limited.add(poi);
      totalMinutes += legMinutes;
      current = poi.location;
    }

    final polyline = [start, ...limited.map((e) => e.location)];
    final legs = <RouteLeg>[];
    for (var i = 0; i < polyline.length - 1; i++) {
      legs.add(_estimateLeg(polyline[i], polyline[i + 1]));
    }

    return RoutePlanResult(
      orderedPois: limited,
      polyline: polyline,
      legs: legs,
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

  RouteLeg _estimateLeg(LatLng from, LatLng to) {
    final meters = _distance.as(LengthUnit.Meter, from, to).round();
    final mode = _chooseMode(meters);
    final speed = switch (mode) {
      TravelMode.walk => _walkingSpeedKmPerHour,
      TravelMode.bike => _bikeSpeedKmPerHour,
      TravelMode.transit => _transitSpeedKmPerHour,
      TravelMode.drive => _driveSpeedKmPerHour,
    };
    final minutes = ((meters / 1000) / speed * 60).ceil().clamp(1, 9999);
    return RouteLeg(
      from: from,
      to: to,
      mode: mode,
      distanceMeters: meters,
      estimatedMinutes: minutes,
    );
  }

  TravelMode _chooseMode(int meters) {
    if (meters <= 1500) return TravelMode.walk;
    if (meters <= 5000) return TravelMode.bike;
    if (meters <= 20000) return TravelMode.transit;
    return TravelMode.drive;
  }
}
