import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/poi.dart';
import 'route_planner_service.dart';

class AiPoiRankingResult {
  const AiPoiRankingResult({required this.topPoiIds});
  final List<String> topPoiIds;
}

class AiRoutePlanResult {
  const AiRoutePlanResult({required this.orderedPoiIds, required this.modes});
  final List<String> orderedPoiIds;
  // Length should be orderedPoiIds.length; each mode corresponds to one leg:
  // start->poi1, poi1->poi2, ...
  final List<TravelMode> modes;
}

class AiPoiDetailResult {
  const AiPoiDetailResult({
    required this.title,
    required this.heroImagePrompt,
    required this.overview,
    required this.highlights,
    required this.tips,
  });

  final String title;
  final String heroImagePrompt;
  final String overview;
  final List<String> highlights;
  final List<String> tips;
}

class AiService {
  AiService()
      : _apiKey = const String.fromEnvironment('DOUBAO_API_KEY', defaultValue: ''),
        _baseUrl = const String.fromEnvironment('DOUBAO_API_BASE_URL', defaultValue: '') {
    _model = const String.fromEnvironment('DOUBAO_MODEL', defaultValue: 'doubao-pro');
    if (_model.trim().isEmpty) {
      // If user didn't provide DOUBAO_MODEL secret, fall back to a sane default.
      // (If Dart defines it as empty string, the default won't apply.)
      _model = 'doubao-pro';
    }
  }

  final String _apiKey;
  final String _baseUrl;
  late String _model;

  bool get _enabled => _apiKey.isNotEmpty && _baseUrl.isNotEmpty;

  /// Rerank candidates using AI.
  Future<AiPoiRankingResult?> rerankPois({
    required List<Poi> candidates,
    required TravelPreference preference,
    required LatLng userLocation,
    required int topK,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!_enabled) return null;
    if (candidates.isEmpty) return const AiPoiRankingResult(topPoiIds: []);

    final payload = {
      'model': _model,
      'messages': [
        {
          'role': 'system',
          'content':
              'You are a travel assistant. Return ONLY valid JSON that matches the schema.'
        },
        {
          'role': 'user',
          'content': jsonEncode({
            'task': 'rank poi candidates for a nearby travel recommendation',
            'user_location': {'lat': userLocation.latitude, 'lng': userLocation.longitude},
            'preference': preference.name,
            'topK': topK,
            'candidates': candidates
                .map((p) => {
                      'id': p.id,
                      'name': p.name,
                      'category': p.category.name,
                      'rating': p.rating,
                      'lat': p.location.latitude,
                      'lng': p.location.longitude,
                      'description': p.description
                    })
                .toList(),
            'return_schema': {
              'top_ids': ['string ...']
            },
            'constraints': [
              'Only select ids that exist in candidates',
              'Order them by best to worst',
              'Return exactly topK ids (or fewer if not enough candidates)'
            ]
          }),
        }
      ],
      'temperature': 0.2
    };

    final raw = await _postJson(payload: payload, timeout: timeout);
    final json = _extractJson(raw);
    if (json == null) return null;

    final list = (json['top_ids'] as List?)?.whereType<String>().toList() ?? const [];
    return AiPoiRankingResult(topPoiIds: list);
  }

  /// Ask AI to output ordered ids and transport mode per leg.
  Future<AiRoutePlanResult?> planRouteWithAI({
    required LatLng start,
    required List<Poi> selectedPois,
    required int timeLimitMinutes,
    required TravelPreference preference,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!_enabled) return null;
    if (selectedPois.isEmpty) {
      return const AiRoutePlanResult(orderedPoiIds: [], modes: []);
    }

    final payload = {
      'model': _model,
      'messages': [
        {
          'role': 'system',
          'content':
              'You are an itinerary planner. Return ONLY valid JSON that matches the schema.'
        },
        {
          'role': 'user',
          'content': jsonEncode({
            'task': 'plan a multi-stop route order and transport modes',
            'start': {'lat': start.latitude, 'lng': start.longitude},
            'time_limit_minutes': timeLimitMinutes,
            'preference': preference.name,
            'pois': selectedPois
                .map((p) => {
                      'id': p.id,
                      'name': p.name,
                      'category': p.category.name,
                      'rating': p.rating,
                      'lat': p.location.latitude,
                      'lng': p.location.longitude,
                      'description': p.description
                    })
                .toList(),
            'allowed_modes': TravelMode.values.map((m) => m.name).toList(),
            'return_schema': {
              'ordered_ids': ['string ...'],
              'modes': ['walk|bike|transit|drive ...'] // same length as ordered_ids
            },
            'constraints': [
              'ordered_ids must be a permutation or subset of provided poi ids',
              'If time_limit is tight, you may output fewer than all pois',
              'modes length must equal ordered_ids length'
            ]
          }),
        }
      ],
      'temperature': 0.2
    };

    final raw = await _postJson(payload: payload, timeout: timeout);

    final json = _extractJson(raw);
    if (json == null) return null;

    final orderedIds = (json['ordered_ids'] as List?)?.whereType<String>().toList() ?? const [];
    final modeStrings = (json['modes'] as List?)?.whereType<String>().toList() ?? const [];
    final modes = <TravelMode>[];
    for (final s in modeStrings.take(orderedIds.length)) {
      final m = _modeFromString(s);
      if (m != null) modes.add(m);
    }

    // If AI returned mismatch, we still return what we parsed.
    return AiRoutePlanResult(orderedPoiIds: orderedIds, modes: modes);
  }

  Future<String> _postJson({
    required Map<String, dynamic> payload,
    required Duration timeout,
  }) async {
    final base = _normalizeBaseUrl(_baseUrl);
    final endpointAttempts = <String>[
      '$base/v1/chat/completions',
      '$base/chat/completions',
    ];

    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (_apiKey.isNotEmpty) 'Authorization': 'Bearer $_apiKey',
    };

    Object? lastError;
    for (final url in endpointAttempts) {
      try {
        final resp = await http
            .post(
              Uri.parse(url),
              headers: headers,
              body: jsonEncode(payload),
            )
            .timeout(timeout);

        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          return resp.body;
        }

        // If not found, try the next endpoint format.
        if (resp.statusCode == 404) {
          lastError = Exception('404 on $url');
          continue;
        }

        throw Exception('AI request failed: ${resp.statusCode} ${resp.body}');
      } catch (e) {
        lastError = e;
      }
    }

    throw Exception('AI request failed on all endpoint attempts. Last error: $lastError');
  }

  static String _normalizeBaseUrl(String baseUrl) {
    var s = baseUrl.trim();
    if (s.endsWith('/')) s = s.substring(0, s.length - 1);
    // If base url already ends with /v1, strip it to avoid /v1/v1
    s = s.replaceFirst(RegExp(r'/v1$'), '');
    return s;
  }

  /// Try to parse the JSON from raw OpenAI-like response.
  ///
  /// If your API differs, tell me the response shape and I’ll adjust.
  Map<String, dynamic>? _extractJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      final content = decoded['choices']?['message']?['content'];
      if (content is String) {
        return jsonDecode(content) as Map<String, dynamic>;
      }
    } catch (_) {
      // fallthrough to heuristic extraction
    }

    // Heuristic: find the first {...} JSON block.
    final first = raw.indexOf('{');
    final last = raw.lastIndexOf('}');
    if (first == -1 || last == -1 || last <= first) return null;
    final block = raw.substring(first, last + 1);
    try {
      return jsonDecode(block) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  TravelMode? _modeFromString(String s) {
    switch (s.toLowerCase()) {
      case 'walk':
      case 'walking':
        return TravelMode.walk;
      case 'bike':
      case 'bicycle':
        return TravelMode.bike;
      case 'transit':
      case 'public_transit':
      case 'public_transport':
      case 'subway':
      case 'metro':
      case 'bus':
        return TravelMode.transit;
      case 'drive':
      case 'driving':
      case 'car':
        return TravelMode.drive;
      default:
        return null;
    }
  }

  Future<AiPoiDetailResult?> describePoiWithAI({
    required Poi poi,
    required TravelPreference preference,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!_enabled) return null;
    final payload = {
      'model': _model,
      'messages': [
        {
          'role': 'system',
          'content':
              'You are a travel writer. Return ONLY valid JSON matching the schema. No markdown fences.'
        },
        {
          'role': 'user',
          'content': jsonEncode({
            'task': 'write a rich travel introduction for a POI',
            'preference': preference.name,
            'poi': {
              'id': poi.id,
              'name': poi.name,
              'category': poi.category.name,
              'rating': poi.rating,
              'description': poi.description,
            },
            'constraints': [
              'Use concise but vivid Chinese.',
              'Highlights: 4-6 items.',
              'Tips: 3-5 actionable tips.'
            ],
            'return_schema': {
              'title': 'string',
              'heroImagePrompt': 'string',
              'overview': 'string',
              'highlights': ['string ...'],
              'tips': ['string ...']
            }
          }),
        }
      ],
      'temperature': 0.4,
    };

    final raw = await _postJson(payload: payload, timeout: timeout);
    final json = _extractJson(raw);
    if (json == null) return null;

    final title = json['title']?.toString() ?? poi.name;
    final prompt = json['heroImagePrompt']?.toString() ?? '';
    final overview = json['overview']?.toString() ?? poi.description;
    final highlights = (json['highlights'] as List?)
            ?.whereType<String>()
            .toList() ??
        const <String>[];
    final tips = (json['tips'] as List?)?.whereType<String>().toList() ?? const <String>[];

    return AiPoiDetailResult(
      title: title,
      heroImagePrompt: prompt,
      overview: overview,
      highlights: highlights,
      tips: tips,
    );
  }
}

