import 'package:latlong2/latlong.dart';

enum TravelPreference {
  food,
  culture,
  nature,
}

class Poi {
  const Poi({
    required this.id,
    required this.name,
    required this.category,
    required this.rating,
    required this.location,
    required this.description,
  });

  final String id;
  final String name;
  final TravelPreference category;
  final double rating;
  final LatLng location;
  final String description;
}
