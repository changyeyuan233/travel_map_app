import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/poi.dart';
import '../services/map_tiles.dart';
import '../services/poi_service.dart';
import '../services/route_planner_service.dart';
import '../services/ai_service.dart';
import 'glass.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _mapController = MapController();
  final _poiService = PoiService();
  final _routePlanner = RoutePlannerService();
  Timer? _poiRefreshDebounce;
  final _aiService = AiService();

  LatLng? _currentLocation;
  List<Poi> _pois = const [];
  final Set<String> _selectedPoiIds = {};

  RoutePlanResult? _routeResult;
  bool _isSelecting = false;
  bool _isLoadingLocation = true;
  String? _locationError;

  Poi? _activePoi;
  bool _showPlanPanel = false;
  double _timeLimitMinutes = 180;
  TravelPreference _travelPreference = TravelPreference.food;

  bool _isAiReranking = false;
  int _aiRerankToken = 0;
  bool _isAiPlanning = false;

  @override
  void initState() {
    super.initState();
    unawaited(_initLocationAndPois());
  }

  Future<void> _initLocationAndPois() async {
    setState(() => _isLoadingLocation = true);
    try {
      final position = await _determinePosition();
      if (!mounted) return;

      final current = LatLng(position.latitude, position.longitude);
      setState(() {
        _currentLocation = current;
        _pois = _poiService.getNearbyRecommendations(current);
        _isLoadingLocation = false;
        _locationError = null;
      });
      // After the first map frame, refresh POIs from visible bounds.
      unawaited(_refreshPoisFromViewport());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingLocation = false;
        _locationError = e.toString();
      });
    }
  }

  Future<void> _refreshPoisFromViewport() async {
    if (!mounted) return;
    if (_isSelecting) return; // avoid UI churn while selecting
    final bounds = _mapController.camera.visibleBounds;
    final candidates =
        _poiService.getRecommendationsForBounds(bounds: bounds, maxCount: 18);

    // Update immediately with local candidates; AI will rerank if enabled.
    setState(() {
      _pois = candidates;
    });

    if (_currentLocation == null) return;
    if (_isAiReranking) return;
    final userLocation = _currentLocation!;

    // Throttle AI calls a bit.
    final token = ++_aiRerankToken;
    _isAiReranking = true;
    try {
      final aiResult = await _aiService.rerankPois(
        candidates: candidates,
        preference: _travelPreference,
        userLocation: userLocation,
        topK: candidates.length,
      );
      if (!mounted) return;
      if (token != _aiRerankToken) return; // out-of-date response
      if (aiResult == null) return;

      final idSet = {for (final id in aiResult.topPoiIds) id};
      final ordered = <Poi>[];
      for (final id in aiResult.topPoiIds) {
        final poi = candidates.where((p) => p.id == id).toList();
        if (poi.isNotEmpty) ordered.add(poi.first);
      }
      // Fill any missing candidates at the end.
      for (final c in candidates) {
        if (!idSet.contains(c.id)) ordered.add(c);
      }

      setState(() {
        _pois = ordered.take(18).toList();
      });
    } finally {
      _isAiReranking = false;
    }
  }

  @override
  void dispose() {
    _poiRefreshDebounce?.cancel();
    super.dispose();
  }

  Future<Position> _determinePosition() async {
    // Web: permissions are handled by the browser (no permission_handler / Android settings).
    if (kIsWeb) {
      return Geolocator.getCurrentPosition();
    }

    var serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      await Geolocator.openLocationSettings();
      serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return Future.error('Location services are disabled.');
      }
    }

    // Android: request runtime permission so MIUI/Xiaomi permission page includes location.
    final status = await Permission.locationWhenInUse.request();
    if (!status.isGranted) {
      if (status.isPermanentlyDenied) {
        return Future.error('Location permission permanently denied. Please enable it in system Settings.');
      }
      return Future.error('Location permission denied.');
    }

    return Geolocator.getCurrentPosition();
  }

  void _centerOnUser() {
    final current = _currentLocation;
    if (current == null) return;
    _mapController.move(current, 15);
  }

  void _toggleSelectionMode() {
    setState(() {
      _isSelecting = !_isSelecting;
      _activePoi = null;
      _showPlanPanel = false;
      if (!_isSelecting) {
        _selectedPoiIds.clear();
      }
    });
  }

  void _onTapPoi(Poi poi) {
    if (_isSelecting) {
      setState(() {
        if (_selectedPoiIds.contains(poi.id)) {
          _selectedPoiIds.remove(poi.id);
        } else {
          _selectedPoiIds.add(poi.id);
        }
      });
      return;
    }

    setState(() => _activePoi = poi);
  }

  void _openPlanPanel() {
    if (_currentLocation == null) return;
    if (_selectedPoiIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('先选择至少 1 个 POI')),
      );
      return;
    }

    setState(() {
      _showPlanPanel = true;
      _activePoi = null;
    });
  }

  void _generateRoute() {
    if (_currentLocation == null) return;
    if (_selectedPoiIds.isEmpty) return;
    if (_isAiPlanning) return;

    unawaited(_generateRouteAsync());
  }

  Future<void> _generateRouteAsync() async {
    setState(() => _isAiPlanning = true);
    try {
      final start = _currentLocation!;
      final selected = _pois.where((p) => _selectedPoiIds.contains(p.id)).toList();

      // Try AI first; if it is disabled or fails, fallback to local optimizer.
      final aiPlan = await _aiService.planRouteWithAI(
        start: start,
        selectedPois: selected,
        timeLimitMinutes: _timeLimitMinutes.toInt(),
        preference: _travelPreference,
      );

      RoutePlanResult result;
      if (aiPlan != null && aiPlan.orderedPoiIds.isNotEmpty) {
        final byId = {for (final p in selected) p.id: p};
        final orderedPois = aiPlan.orderedPoiIds
            .map((id) => byId[id])
            .whereType<Poi>()
            .toList();
        result = _routePlanner.planFromOrderAndModes(
          start: start,
          orderedPois: orderedPois,
          modes: aiPlan.modes,
          timeLimitMinutes: _timeLimitMinutes.toInt(),
        );
      } else {
        result = _routePlanner.plan(
          start: start,
          selectedPois: selected,
          timeLimitMinutes: _timeLimitMinutes.toInt(),
          preference: _travelPreference,
        );
      }

      if (!mounted) return;
      setState(() {
        _routeResult = result;
        _isSelecting = false;
        _selectedPoiIds.clear();
        _showPlanPanel = false;
      });
    } catch (_) {
      // If AI fails, still fallback to local plan.
      if (!mounted) return;
      final start = _currentLocation!;
      final selected = _pois.where((p) => _selectedPoiIds.contains(p.id)).toList();
      final result = _routePlanner.plan(
        start: start,
        selectedPois: selected,
        timeLimitMinutes: _timeLimitMinutes.toInt(),
        preference: _travelPreference,
      );
      setState(() {
        _routeResult = result;
        _isSelecting = false;
        _selectedPoiIds.clear();
        _showPlanPanel = false;
      });
    } finally {
      if (mounted) setState(() => _isAiPlanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = _currentLocation;
    if (_isLoadingLocation) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (current == null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: GlassCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '无法获取定位',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 18),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _locationError ?? '未知错误',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 14),
                  FilledButton(
                    onPressed: () {
                      setState(() => _locationError = null);
                      _initLocationAndPois();
                    },
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: current,
              initialZoom: 14,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
              onPositionChanged: (pos, hasGesture) {
                if (!hasGesture) return;
                _poiRefreshDebounce?.cancel();
                _poiRefreshDebounce = Timer(const Duration(milliseconds: 450), () {
                  unawaited(_refreshPoisFromViewport());
                });
              },
            ),
            children: [
              TileLayer(
                // Always use AMap tiles (requirement). Provide AMAP_API_KEY via env if needed.
                urlTemplate: MapTiles.amapTileUrlTemplate(
                  apiKey: const String.fromEnvironment('AMAP_API_KEY', defaultValue: ''),
                ),
                userAgentPackageName: 'com.example.travel_map_app',
              ),
              MarkerLayer(markers: _buildPoiMarkers()),
              if ((_routeResult?.orderedPois.length ?? 0) > 0)
                MarkerLayer(markers: _buildRouteStopMarkers()),
              MarkerLayer(
                markers: [
                  Marker(
                    point: current,
                    width: 40,
                    height: 40,
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.blueAccent.withOpacity(0.85), width: 2),
                        color: Colors.blueAccent.withOpacity(0.18),
                      ),
                      child: const Center(
                        child: Icon(Icons.my_location, color: Colors.blueAccent, size: 18),
                      ),
                    ),
                  ),
                ],
              ),
              if ((_routeResult?.polyline.length ?? 0) > 1)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _routeResult!.polyline,
                      strokeWidth: 4.5,
                      color: Colors.deepOrange.withOpacity(0.92),
                    ),
                  ],
                ),
            ],
          ),
          Positioned(
            top: 48,
            left: 12,
            right: 12,
            child: _TopGlassInfo(
              isSelecting: _isSelecting,
              routeMinutes: _routeResult?.estimatedMinutes,
              routeStops: _routeResult?.orderedPois.length,
              selectedCount: _selectedPoiIds.length,
              legs: _routeResult?.legs,
            ),
          ),
          Positioned(
            right: 16,
            bottom: 160,
            child: GlassIconButton(
              onPressed: _centerOnUser,
              icon: const Icon(Icons.gps_fixed, color: Colors.white, size: 18),
            ),
          ),
          Positioned(
            right: 16,
            bottom: 96,
            child: GlassPillButton(
              onPressed: _toggleSelectionMode,
              icon: Icon(
                _isSelecting ? Icons.close : Icons.checklist,
                size: 18,
                color: Colors.white,
              ),
              child: Text(_isSelecting ? '取消选点' : '多选 POI'),
            ),
          ),
          if (_isSelecting)
            Positioned(
              right: 16,
              bottom: 24,
              child: GlassPillButton(
                onPressed: _openPlanPanel,
                icon: const Icon(Icons.route, size: 18, color: Colors.white),
                child: Text('规划 (${_selectedPoiIds.length})'),
              ),
            ),
          if (_activePoi != null && !_isSelecting)
            Positioned(
              left: 12,
              right: 12,
              bottom: 16,
              child: GlassCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _activePoi!.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          onPressed: () => setState(() => _activePoi = null),
                          icon: const Icon(Icons.close, color: Colors.white, size: 20),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(Icons.star, size: 16, color: Colors.amber),
                        const SizedBox(width: 6),
                        Text(
                          _activePoi!.rating.toStringAsFixed(1) + ' / 5.0',
                          style: const TextStyle(color: Colors.white70),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          _activePoi!.category.name,
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _activePoi!.description,
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          if (_showPlanPanel)
            Positioned(
              left: 12,
              right: 12,
              bottom: 16,
              child: GlassCard(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          '路线约束',
                          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: () => setState(() => _showPlanPanel = false),
                          icon: const Icon(Icons.close, color: Colors.white, size: 20),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      '时间上限：${_timeLimitMinutes.toInt()} 分钟',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    Slider(
                      min: 30,
                      max: 480,
                      divisions: 15,
                      value: _timeLimitMinutes,
                      onChanged: (v) => setState(() => _timeLimitMinutes = v),
                    ),
                    DropdownButton<TravelPreference>(
                      value: _travelPreference,
                      isExpanded: true,
                      dropdownColor: Colors.black.withOpacity(0.85),
                      underline: const SizedBox(),
                      style: const TextStyle(color: Colors.white),
                      items: TravelPreference.values
                          .map(
                            (e) => DropdownMenuItem(
                              value: e,
                              child: Text('偏好：${e.name}'),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() => _travelPreference = v);
                      },
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: GlassPillButton(
                            onPressed: () => setState(() => _showPlanPanel = false),
                            icon: const Icon(Icons.cancel, size: 18, color: Colors.white),
                            child: const Text('取消'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: GlassPillButton(
                            onPressed: _generateRoute,
                            icon: const Icon(Icons.check, size: 18, color: Colors.white),
                            child: const Text('生成路线'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Marker> _buildPoiMarkers() {
    return _pois.map((poi) {
      final isSelected = _selectedPoiIds.contains(poi.id);
      final icon = _categoryIcon(poi.category);
      return Marker(
        point: poi.location,
        width: 46,
        height: 46,
        child: GestureDetector(
          onTap: () => _onTapPoi(poi),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isSelected ? Colors.deepOrange.withOpacity(0.95) : Colors.white.withOpacity(0.12),
              border: Border.all(
                color: isSelected ? Colors.white.withOpacity(0.9) : Colors.white.withOpacity(0.2),
                width: 1.2,
              ),
              boxShadow: const [
                BoxShadow(color: Colors.black38, blurRadius: 10, offset: Offset(0, 4)),
              ],
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      poi.rating.toStringAsFixed(1),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const Text(
                      '★',
                      style: TextStyle(
                        fontSize: 11,
                        height: 0.9,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
                Positioned(
                  top: 1,
                  right: 1,
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withOpacity(0.25),
                      border: Border.all(color: Colors.white.withOpacity(0.14), width: 1),
                    ),
                    padding: const EdgeInsets.all(4),
                    child: icon,
                  ),
                )
              ],
            ),
          ),
        ),
      );
    }).toList();
  }

  Widget _categoryIcon(TravelPreference category) {
    IconData iconData;
    switch (category) {
      case TravelPreference.food:
        iconData = Icons.restaurant;
        break;
      case TravelPreference.culture:
        iconData = Icons.theater_comedy;
        break;
      case TravelPreference.nature:
        iconData = Icons.park;
        break;
    }
    return Icon(iconData, color: Colors.white, size: 12);
  }

  List<Marker> _buildRouteStopMarkers() {
    final result = _routeResult;
    if (result == null || result.orderedPois.isEmpty) return const [];

    final markers = <Marker>[];
    for (var i = 0; i < result.orderedPois.length; i++) {
      final point = result.orderedPois[i].location;
      markers.add(
        Marker(
          point: point,
          width: 34,
          height: 34,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.deepOrange.withOpacity(0.95),
              border: Border.all(color: Colors.white.withOpacity(0.8), width: 1),
            ),
            child: Center(
              child: Text(
                '${i + 1}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ),
      );
    }
    return markers;
  }
}

class _TopGlassInfo extends StatelessWidget {
  const _TopGlassInfo({
    required this.isSelecting,
    required this.routeMinutes,
    required this.routeStops,
    required this.selectedCount,
    required this.legs,
  });

  final bool isSelecting;
  final int? routeMinutes;
  final int? routeStops;
  final int selectedCount;
  final List<RouteLeg>? legs;

  @override
  Widget build(BuildContext context) {
    final text = isSelecting
        ? '选点中：点击 POI 加/减'
        : routeMinutes != null && routeStops != null && routeStops != 0
            ? '已规划：$routeStops 点，约 $routeMinutes 分钟'
            : '附近 POI 推荐';

    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      opacity: 0.55,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (isSelecting && selectedCount > 0)
            Text(
              '已选 $selectedCount',
              style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700),
            ),
          if (isSelecting && selectedCount > 0) const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
          ),
          if (!isSelecting && (legs?.isNotEmpty ?? false)) ...[
            const SizedBox(width: 10),
            _ModePills(legs: legs!),
          ],
        ],
      ),
    );
  }
}

class _ModePills extends StatelessWidget {
  const _ModePills({required this.legs});

  final List<RouteLeg> legs;

  @override
  Widget build(BuildContext context) {
    // Show up to 3 legs to keep the bar minimal.
    final show = legs.take(3).toList();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final leg in show)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.14),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white.withOpacity(0.22), width: 1),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_iconFor(leg.mode), size: 14, color: Colors.white),
                  const SizedBox(width: 6),
                  Text(
                    '${leg.estimatedMinutes}m',
                    style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  static IconData _iconFor(TravelMode mode) {
    switch (mode) {
      case TravelMode.walk:
        return Icons.directions_walk;
      case TravelMode.bike:
        return Icons.directions_bike;
      case TravelMode.transit:
        return Icons.directions_transit;
      case TravelMode.drive:
        return Icons.directions_car;
    }
  }
}
