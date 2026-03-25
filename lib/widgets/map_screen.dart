import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../models/poi.dart';
import '../services/map_tiles.dart';
import '../services/poi_service.dart';
import '../services/route_planner_service.dart';
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

  LatLng? _currentLocation;
  List<Poi> _pois = const [];
  final Set<String> _selectedPoiIds = {};

  RoutePlanResult? _routeResult;
  bool _isSelecting = false;
  bool _isLoadingLocation = true;

  Poi? _activePoi;
  bool _showPlanPanel = false;
  double _timeLimitMinutes = 180;
  TravelPreference _travelPreference = TravelPreference.food;

  @override
  void initState() {
    super.initState();
    unawaited(_initLocationAndPois());
  }

  Future<void> _initLocationAndPois() async {
    setState(() => _isLoadingLocation = true);
    final position = await _determinePosition();
    if (!mounted) return;

    final current = LatLng(position.latitude, position.longitude);
    setState(() {
      _currentLocation = current;
      _pois = _poiService.getNearbyRecommendations(current);
      _isLoadingLocation = false;
    });
  }

  Future<Position> _determinePosition() async {
    var serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      await Geolocator.openLocationSettings();
      serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return Future.error('Location services are disabled.');
      }
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      return Future.error('Location permissions are denied.');
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

    final selected = _pois.where((p) => _selectedPoiIds.contains(p.id)).toList();
    final result = _routePlanner.plan(
      start: _currentLocation!,
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Unable to get location.'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _initLocationAndPois,
                child: const Text('Retry'),
              ),
            ],
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
            ),
            children: [
              TileLayer(
                urlTemplate: (() {
                  const amapKey = String.fromEnvironment('AMAP_API_KEY', defaultValue: '');
                  if (amapKey.isEmpty) {
                    return 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
                  }
                  return MapTiles.amapTileUrlTemplate(apiKey: amapKey);
                })(),
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
  });

  final bool isSelecting;
  final int? routeMinutes;
  final int? routeStops;
  final int selectedCount;

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
        ],
      ),
    );
  }
}
