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
import '../services/amap_routing_service.dart';
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
  final _amapRouting = AmapRoutingService();

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

  List<List<LatLng>> _routeLegTracks = const [];

  AiPoiDetailResult? _activePoiDetail;
  bool _isPoiDetailLoading = false;
  int _poiDetailToken = 0;

  double get _currentZoom => _mapController.camera.zoom;
  double _uiZoom = 14;

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
      _activePoiDetail = null;
      _isPoiDetailLoading = false;
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

    final token = ++_poiDetailToken;
    setState(() {
      _activePoi = poi;
      _activePoiDetail = null;
      _isPoiDetailLoading = true;
    });
    unawaited(_loadPoiDetailWithAI(poi, token));
  }

  Future<void> _loadPoiDetailWithAI(Poi poi, int token) async {
    try {
      final detail = await _aiService.describePoiWithAI(
        poi: poi,
        preference: _travelPreference,
      );
      if (!mounted) return;
      if (token != _poiDetailToken) return;
      setState(() {
        _activePoiDetail = detail;
        _isPoiDetailLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      if (token != _poiDetailToken) return;
      setState(() {
        _activePoiDetail = null;
        _isPoiDetailLoading = false;
      });
    }
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

      // Fetch road-aligned tracks for each leg.
      final legs = result.legs;
      final tracks = <List<LatLng>>[];
      for (var i = 0; i < legs.length; i++) {
        final leg = legs[i];
        // Avoid too many API calls; MVP keeps it reasonable.
        if (i >= 6) break;
        try {
          final track = await _amapRouting.fetchLegTrack(
            from: leg.from,
            to: leg.to,
            mode: leg.mode,
          );
          if (track.length >= 2) {
            tracks.add(track);
          } else {
            tracks.add([leg.from, leg.to]);
          }
        } catch (_) {
          tracks.add([leg.from, leg.to]);
        }
      }

      if (!mounted) return;
      setState(() {
        _routeResult = result;
        _routeLegTracks = tracks;
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
        _routeLegTracks = const [];
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

    final showPoiCards = _uiZoom <= 12.5 && !_isSelecting && _activePoi == null;
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
                if ((pos.zoom - _uiZoom).abs() > 0.2) {
                  setState(() => _uiZoom = pos.zoom);
                }
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
              MarkerLayer(markers: showPoiCards ? const [] : _buildPoiMarkers()),
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
                  polylines: _buildRoutePolylines(),
                ),
            ],
          ),
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: Column(
              children: [
                GlassCard(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                  borderRadius: 18,
                  opacity: 0.45,
                  blurSigma: 22,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Icon(Icons.location_on_outlined, size: 18, color: Colors.white),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '当前位置',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        onPressed: () {},
                        icon: const Icon(Icons.search, color: Colors.white, size: 20),
                        padding: EdgeInsets.zero,
                      ),
                      IconButton(
                        onPressed: () {},
                        icon: const Icon(Icons.person_outline, color: Colors.white, size: 20),
                        padding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                GlassCard(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  borderRadius: 18,
                  opacity: 0.35,
                  blurSigma: 20,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _prefChip(TravelPreference.food, Icons.restaurant, '美食'),
                      _prefChip(TravelPreference.culture, Icons.theater_comedy, '景点'),
                      _prefChip(TravelPreference.nature, Icons.park, '自然'),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                GlassCard(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  borderRadius: 16,
                  opacity: 0.35,
                  blurSigma: 18,
                  child: Row(
                    children: [
                      const Icon(Icons.layers, size: 16, color: Colors.white70),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _isSelecting
                              ? '已选 ${_selectedPoiIds.length} 个'
                              : (_routeResult != null && (_routeResult?.orderedPois.length ?? 0) > 0)
                                  ? '已规划：${_routeResult!.orderedPois.length} 点 · 约 ${_routeResult!.estimatedMinutes} 分'
                                  : '附近推荐',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (showPoiCards)
            Positioned(
              left: 12,
              right: 12,
              bottom: 110,
              child: SizedBox(
                height: 250,
                child: ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: _pois.take(6).length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (ctx, i) {
                    final poi = _pois[i];
                    final selected = _selectedPoiIds.contains(poi.id);
                    return InkWell(
                      onTap: () => _onTapPoi(poi),
                      borderRadius: BorderRadius.circular(18),
                      child: GlassCard(
                        padding: const EdgeInsets.all(12),
                        borderRadius: 18,
                        opacity: 0.45,
                        blurSigma: 20,
                        child: Stack(
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 92,
                                  height: 76,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(14),
                                    color: _categoryColor(poi.category).withOpacity(0.22),
                                    border: Border.all(
                                      color: _categoryColor(poi.category).withOpacity(0.35),
                                      width: 1,
                                    ),
                                  ),
                                  child: Center(
                                    child: _categoryIcon(poi.category),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        poi.name,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w900,
                                          fontSize: 15,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 6),
                                      Row(
                                        children: [
                                          const Icon(Icons.star, size: 14, color: Colors.amber),
                                          const SizedBox(width: 6),
                                          Text(
                                            poi.rating.toStringAsFixed(1),
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontWeight: FontWeight.w800,
                                              fontSize: 13,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        poi.category.name,
                                        style: TextStyle(
                                          color: _categoryColor(poi.category).withOpacity(0.95),
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            if (selected)
                              Positioned(
                                right: 0,
                                top: 0,
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.deepOrange.withOpacity(0.92),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Icon(Icons.check, size: 18, color: Colors.white),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          Positioned(
            left: 14,
            right: 14,
            bottom: 20,
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: _toggleSelectionMode,
                      borderRadius: BorderRadius.circular(18),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.card_travel,
                            size: 22,
                            color: _isSelecting ? Colors.white : Colors.white70,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '行程',
                            style: TextStyle(
                              color: _isSelecting ? Colors.white : Colors.white70,
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  InkWell(
                    onTap: () {
                      if (_isSelecting) {
                        _openPlanPanel();
                      } else {
                        _centerOnUser();
                      }
                    },
                    borderRadius: BorderRadius.circular(999),
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.86),
                        borderRadius: BorderRadius.circular(999),
                        boxShadow: const [
                          BoxShadow(color: Colors.black26, blurRadius: 16, offset: Offset(0, 8)),
                        ],
                      ),
                      child: const Center(
                        child: Icon(Icons.add, color: Colors.white, size: 30),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: InkWell(
                      onTap: () {
                        if (_isSelecting) _toggleSelectionMode();
                        setState(() {
                          _showPlanPanel = false;
                          _activePoi = null;
                          _activePoiDetail = null;
                          _isPoiDetailLoading = false;
                        });
                      },
                      borderRadius: BorderRadius.circular(18),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.place,
                            size: 22,
                            color: !_isSelecting ? Colors.white : Colors.white70,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '附近',
                            style: TextStyle(
                              color: !_isSelecting ? Colors.white : Colors.white70,
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_activePoi != null && !_isSelecting)
            Positioned(
              left: 12,
              right: 12,
              bottom: 110,
              child: GlassCard(
                padding: const EdgeInsets.all(14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 92,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              gradient: const LinearGradient(
                                colors: [Color(0xFF2A7FFF), Color(0xFF7A5CFF)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                            ),
                          ),
                          Positioned(
                            left: 12,
                            top: 12,
                            child: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.22),
                                border: Border.all(color: Colors.white.withOpacity(0.16)),
                                shape: BoxShape.circle,
                              ),
                              child: _categoryIcon(_activePoi!.category),
                            ),
                          ),
                          Positioned(
                            right: 12,
                            top: 12,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.22),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(color: Colors.white.withOpacity(0.16)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.star, size: 14, color: Colors.amber),
                                  const SizedBox(width: 6),
                                  Text(
                                    _activePoi!.rating.toStringAsFixed(1),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            (_activePoiDetail?.title ?? _activePoi!.name),
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
                          onPressed: () => setState(() {
                            _activePoi = null;
                            _activePoiDetail = null;
                            _isPoiDetailLoading = false;
                          }),
                          icon: const Icon(Icons.close, color: Colors.white, size: 20),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    if (_isPoiDetailLoading)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 10),
                            const Text(
                              'AI 生成介绍中...',
                              style: TextStyle(color: Colors.white70, fontSize: 13),
                            ),
                          ],
                        ),
                      )
                    else ...[
                      Text(
                        _activePoiDetail?.overview ??
                            _activePoi!.description,
                        style: const TextStyle(color: Colors.white70, fontSize: 13),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if ((_activePoiDetail?.highlights.isNotEmpty ?? false))
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: _activePoiDetail!.highlights
                                .take(5)
                                .map(
                                  (h) => Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(color: Colors.white.withOpacity(0.16)),
                                    ),
                                    child: Text(
                                      h,
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      if ((_activePoiDetail?.tips.isNotEmpty ?? false))
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '小贴士',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 6),
                              for (final tip in _activePoiDetail!.tips.take(3))
                                Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 3),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.check_circle, size: 14, color: Colors.lightGreenAccent),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          tip,
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 12,
                                            height: 1.25,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          if (_showPlanPanel)
            Positioned(
              left: 12,
              right: 12,
              bottom: 110,
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
      final categoryColor = _categoryColor(poi.category);
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
              color: isSelected ? Colors.deepOrange.withOpacity(0.95) : categoryColor.withOpacity(0.18),
              border: Border.all(
                color: isSelected ? Colors.white.withOpacity(0.9) : categoryColor.withOpacity(0.3),
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
                      color: Colors.black.withOpacity(0.22),
                      border: Border.all(color: Colors.white.withOpacity(0.16), width: 1),
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

  Color _categoryColor(TravelPreference category) {
    switch (category) {
      case TravelPreference.food:
        return const Color(0xFFFF8A65);
      case TravelPreference.culture:
        return const Color(0xFF7C4DFF);
      case TravelPreference.nature:
        return const Color(0xFF4DD0E1);
    }
  }

  Widget _prefChip(TravelPreference pref, IconData icon, String label) {
    final selected = _travelPreference == pref;
    final c = _categoryColor(pref);
    return GestureDetector(
      onTap: () {
        if (selected) return;
        setState(() => _travelPreference = pref);
        unawaited(_refreshPoisFromViewport());
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? c.withOpacity(0.18) : Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? c.withOpacity(0.55) : Colors.white.withOpacity(0.12),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: selected ? Colors.white : c.withOpacity(0.95)),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : Colors.white70,
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
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

extension _RoutePolylineColor on _MapScreenState {
  List<Polyline> _buildRoutePolylines() {
    final result = _routeResult;
    if (result == null) return const [];

    final legs = result.legs;
    if (legs.isEmpty) {
      return [
        Polyline(
          points: result.polyline,
          strokeWidth: 4.5,
          color: Colors.deepOrange.withOpacity(0.92),
        ),
      ];
    }

    if (_routeLegTracks.isNotEmpty && _routeLegTracks.length == legs.length) {
      return [
        for (var i = 0; i < legs.length; i++)
          Polyline(
            points: _routeLegTracks[i],
            strokeWidth: 5,
            color: _modeColor(legs[i].mode).withOpacity(0.95),
          ),
      ];
    }

    // Fallback: straight segments (should be replaced once AMap track returns).
    return legs
        .map((leg) => Polyline(
              points: [leg.from, leg.to],
              strokeWidth: 5,
              color: _modeColor(leg.mode).withOpacity(0.95),
            ))
        .toList();
  }

  Color _modeColor(TravelMode mode) {
    switch (mode) {
      case TravelMode.walk:
        return Colors.lightBlueAccent;
      case TravelMode.bike:
        return Colors.greenAccent;
      case TravelMode.transit:
        return Colors.purpleAccent;
      case TravelMode.drive:
        return Colors.deepOrangeAccent;
    }
  }
}
