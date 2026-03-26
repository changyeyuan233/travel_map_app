import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/poi.dart';
import 'route_planner_service.dart';

class AmapRoutingService {
  AmapRoutingService()
      : _apiKey = const String.fromEnvironment('AMAP_API_KEY', defaultValue: '');

  final String _apiKey;

  bool get _enabled => _apiKey.trim().isNotEmpty;

  Future<List<LatLng>> fetchLegTrack({
    required LatLng from,
    required LatLng to,
    required TravelMode mode,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!_enabled) return const [];

    final origin = '${from.longitude},${from.latitude}';
    final destination = '${to.longitude},${to.latitude}';

    final endpoints = <String>[
      // Prefer mode-specific endpoints.
      if (mode == TravelMode.walk) 'https://restapi.amap.com/v3/direction/walking',
      if (mode == TravelMode.drive) 'https://restapi.amap.com/v3/direction/driving',
      if (mode == TravelMode.transit)
        'https://restapi.amap.com/v3/direction/transit/integrated',
      if (mode == TravelMode.bike) 'https://restapi.amap.com/v4/direction/bicycling',
      // Fallbacks in case a provider doesn't support the mode in this region.
      'https://restapi.amap.com/v3/direction/driving',
      'https://restapi.amap.com/v3/direction/walking',
    ];

    for (final base in endpoints) {
      try {
        final url = Uri.parse(base).replace(queryParameters: {
          'key': _apiKey,
          'origin': origin,
          'destination': destination,
          'output': 'json',
        });

        final res = await http.get(url).timeout(timeout);
        if (res.statusCode < 200 || res.statusCode >= 300) continue;

        final json = jsonDecode(res.body) as Map<String, dynamic>;
        final track = _extractPolylines(json);
        if (track.length >= 2) return track;
      } catch (_) {
        // try next endpoint
      }
    }

    return const [];
  }

  List<LatLng> _extractPolylines(dynamic node) {
    final points = <LatLng>[];

    void walk(dynamic n) {
      if (n == null) return;
      if (n is String) {
        // Not safe to parse arbitrary strings.
        return;
      }
      if (n is Map) {
        n.forEach((k, v) {
          if (k == 'polyline' && v is String) {
            points.addAll(_parsePolylineString(v));
          } else {
            walk(v);
          }
        });
        return;
      }
      if (n is List) {
        for (final item in n) {
          walk(item);
        }
        return;
      }
    }

    walk(node);

    // De-dup consecutive points to reduce rendering jitter.
    final deduped = <LatLng>[];
    for (final p in points) {
      if (deduped.isEmpty) {
        deduped.add(p);
        continue;
      }
      final last = deduped.last;
      if ((last.latitude - p.latitude).abs() < 1e-7 && (last.longitude - p.longitude).abs() < 1e-7) {
        continue;
      }
      deduped.add(p);
    }
    return deduped;
  }

  List<LatLng> _parsePolylineString(String s) {
    // Expected format: "lng,lat;lng,lat;..."
    final pairs = s.split(';').where((e) => e.trim().isNotEmpty).toList();
    final result = <LatLng>[];
    for (final pair in pairs) {
      final xy = pair.split(',');
      if (xy.length != 2) continue;
      final lon = double.tryParse(xy[0]);
      final lat = double.tryParse(xy[1]);
      if (lon == null || lat == null) continue;
      result.add(LatLng(lat, lon));
    }
    return result;
  }
}

