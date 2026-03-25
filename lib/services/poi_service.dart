import 'dart:math';

import 'package:latlong2/latlong.dart';

import '../models/poi.dart';

class PoiService {
  static const _distance = Distance();

  /// Generates nearby mock POIs around current location.
  /// Replace this with a real POI API integration in production.
  List<Poi> getNearbyRecommendations(LatLng current) {
    final random = Random(current.latitude.toInt() + current.longitude.toInt());
    final prefs = TravelPreference.values;

    return List.generate(12, (i) {
      final offsetLat = (random.nextDouble() - 0.5) * 0.03;
      final offsetLng = (random.nextDouble() - 0.5) * 0.03;
      final category = prefs[i % prefs.length];
      final location = LatLng(current.latitude + offsetLat, current.longitude + offsetLng);

      return Poi(
        id: 'poi_$i',
        name: _nameFor(category, i),
        category: category,
        rating: (3.5 + random.nextDouble() * 1.5).clamp(0, 5),
        location: location,
        description: _descriptionFor(category),
      );
    })
      ..sort(
        (a, b) => _distance
            .as(LengthUnit.Meter, current, a.location)
            .compareTo(_distance.as(LengthUnit.Meter, current, b.location)),
      );
  }

  String _nameFor(TravelPreference pref, int i) {
    switch (pref) {
      case TravelPreference.food:
        return 'Food Spot ${i + 1}';
      case TravelPreference.culture:
        return 'Culture Place ${i + 1}';
      case TravelPreference.nature:
        return 'Nature View ${i + 1}';
    }
  }

  String _descriptionFor(TravelPreference pref) {
    switch (pref) {
      case TravelPreference.food:
        return 'Popular local food recommendation.';
      case TravelPreference.culture:
        return 'Interesting place with local culture.';
      case TravelPreference.nature:
        return 'Relaxing outdoor location for sightseeing.';
    }
  }
}
