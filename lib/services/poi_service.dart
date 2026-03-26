import 'dart:math';

import 'package:latlong2/latlong.dart';

import '../models/poi.dart';

class PoiService {
  static const _distance = Distance();

  /// Generates mock POIs within the visible map bounds.
  ///
  /// Replace this with AMap/Google POI API in production.
  List<Poi> getRecommendationsForBounds({
    required LatLngBounds bounds,
    required int maxCount,
  }) {
    // Make results stable-ish as user drags/zooms.
    final seed = (bounds.southWest.latitude * 1000).round() ^
        (bounds.southWest.longitude * 1000).round() ^
        (bounds.northEast.latitude * 1000).round() ^
        (bounds.northEast.longitude * 1000).round();
    final random = Random(seed);

    final prefs = TravelPreference.values;

    // Generate more candidates than we need, then pick the highest-rated inside bounds.
    final candidates = <Poi>[];
    const candidateCount = 220;
    for (var i = 0; i < candidateCount; i++) {
      final lat = bounds.southWest.latitude +
          random.nextDouble() * (bounds.northEast.latitude - bounds.southWest.latitude);
      final lng = bounds.southWest.longitude +
          random.nextDouble() * (bounds.northEast.longitude - bounds.southWest.longitude);
      final category = prefs[i % prefs.length];
      candidates.add(
        Poi(
          id: 'poi_${seed}_$i',
          name: _nameFor(category, i),
          category: category,
          rating: (3.2 + random.nextDouble() * 1.8).clamp(0, 5),
          location: LatLng(lat, lng),
          description: _descriptionFor(category),
        ),
      );
    }

    candidates.sort((a, b) => b.rating.compareTo(a.rating));
    return candidates.take(maxCount).toList();
  }

  /// Backward compatible helper: near-current recommendations (small radius).
  List<Poi> getNearbyRecommendations(LatLng current) {
    final span = 0.03;
    return getRecommendationsForBounds(
      bounds: LatLngBounds(
        LatLng(current.latitude - span / 2, current.longitude - span / 2),
        LatLng(current.latitude + span / 2, current.longitude + span / 2),
      ),
      maxCount: 12,
    )..sort(
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
