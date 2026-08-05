import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'; // НОВОЕ
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GPS Map App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.blue,
        scaffoldBackgroundColor: const Color(0xFF121212),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _showMap = false;

  void _openMap() {
    setState(() {
      _showMap = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: _showMap ? const MapScreen() : const SizedBox(),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton.icon(
              onPressed: _openMap,
              icon: const Icon(Icons.map),
              label: const Text('Открыть карту телеметрии'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen>
    with SingleTickerProviderStateMixin {
  final MapController _mapController = MapController();

  String _mapStyle = 'dark';
  double _compassOffset = 30.0;
  bool _courseUp = false;

  LatLng? _displayedPosition;

  double _heading = 0;
  double _displayRotation = 0;
  bool _headingInitialized = false;

  String _statusText = 'Определяем местоположение пилота...';
  StreamSubscription<Position>? _positionStream;
  StreamSubscription<CompassEvent>? _compassStream;

  late final AnimationController _animController;
  Animation<double>? _latAnim;
  Animation<double>? _lngAnim;
  bool _followMe = true;

  LatLng? _gliderPosition;
  double _gliderAlt = 0.0;
  int _gliderSats = 0;
  bool _gliderFix = false;
  double _gliderAccX = 0.0;
  double _gliderAccY = 0.0;
  double _gliderAccZ = 0.0;
  bool _gliderParaActive = false;

  RawDatagramSocket? _udpSocket;

  bool _isSimulationActive = false;
  Timer? _simulationTimer;

  final List<LatLng> _recentPositions = [];
  static const int _smoothingWindow = 3;
  static const double _maxAcceptableAccuracy = 15.0;

  @override
  void initState() {
    super.initState();

    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    _initLocationTracking();
    _initCompass();
    _initUDPListener();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _compassStream?.cancel();
    _animController.dispose();
    _udpSocket?.close();
    _simulationTimer?.cancel();
    super.dispose();
  }

  void _initUDPListener() async {
    try {
      _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 5555);
      _udpSocket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          Datagram? dg = _udpSocket!.receive();
          if (dg != null) {
            String message = utf8.decode(dg.data);
            _parseGliderTelemetry(message);
          }
        }
      });
      print("Слушатель UDP запущен на порту 5555");
    } catch (e) {
      print("Ошибка запуска UDP сокета: $e");
    }
  }

  void _sendCommandToGlider(String command) {
    if (_udpSocket != null) {
      _udpSocket!.send(
        utf8.encode(command),
        InternetAddress('192.168.4.1'),
        5555,
      );
      print("Отправлена команда по UDP: $command");
    }
  }

  void _parseGliderTelemetry(String packet) {
    if (_isSimulationActive) return;
    if (!packet.startsWith('G')) return;

    try {
      String data = packet.substring(1);
      List<String> parts = data.split(',');
      if (parts.length >= 9) {
        double lat = double.parse(parts[0]);
        double lng = double.parse(parts[1]);
        double alt = double.parse(parts[2]);
        int sats = int.parse(parts[3]);
        bool fix = parts[4] == '1';
        double accX = double.parse(parts[5]);
        double accY = double.parse(parts[6]);
        double accZ = double.parse(parts[7]);
        bool paraOn = parts[8] == '1';

        setState(() {
          _gliderPosition = LatLng(lat, lng);
          _gliderAlt = alt;
          _gliderSats = sats;
          _gliderFix = fix;
          _gliderAccX = accX;
          _gliderAccY = accY;
          _gliderAccZ = accZ;
          _gliderParaActive = paraOn;
        });
      }
    } catch (e) {
      print("Ошибка разбора телеметрии: $e");
    }
  }

  void _toggleSimulation(bool value) {
    setState(() {
      _isSimulationActive = value;
    });

    if (_isSimulationActive) {
      _simulationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (_displayedPosition == null) return;

        double angle = timer.tick * 0.08;
        double radius = 0.0015;
        double simLat = _displayedPosition!.latitude + radius * math.sin(angle);
        double simLng = _displayedPosition!.longitude + radius * math.cos(angle);

        setState(() {
          _gliderPosition = LatLng(simLat, simLng);
          _gliderAlt = 150.0 + (math.sin(angle) * 35.0);
          _gliderSats = 9;
          _gliderFix = true;
          _gliderAccX = 0.05 * math.sin(angle);
          _gliderAccY = -0.12 * math.cos(angle);
          _gliderAccZ = 9.81 + (1.2 * math.sin(angle));
        });
      });
    } else {
      _simulationTimer?.cancel();
      setState(() {
        _gliderPosition = null;
      });
    }
  }

  void _initCompass() {
    if (FlutterCompass.events != null) {
      _compassStream = FlutterCompass.events!.listen((event) {
        if (event.heading == null) return;

        double rawHeading = (event.heading! + _compassOffset) % 360;
        if (rawHeading < 0) rawHeading += 360;

        double smoothed;
        if (!_headingInitialized) {
          smoothed = rawHeading;
          _headingInitialized = true;
        } else {
          const double smoothingFactor = 0.15;
          double oldRad = _heading * math.pi / 180.0;
          double newRad = rawHeading * math.pi / 180.0;

          double sinAvg = (1 - smoothingFactor) * math.sin(oldRad) +
              smoothingFactor * math.sin(newRad);
          double cosAvg = (1 - smoothingFactor) * math.cos(oldRad) +
              smoothingFactor * math.cos(newRad);

          smoothed = math.atan2(sinAvg, cosAvg) * 180.0 / math.pi;
          if (smoothed < 0) smoothed += 360;
        }

        double delta = smoothed - _heading;
        if (delta > 180) delta -= 360;
        if (delta < -180) delta += 360;

        setState(() {
          _heading = smoothed;
          _displayRotation += delta;
        });

        if (_courseUp) {
          _mapController.rotate(-_heading);
        }
      });
    }
  }

  Future<void> _initLocationTracking() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() {
        _statusText = 'Включите GPS в настройках телефона';
      });
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() {
          _statusText = 'Разрешение на геолокацию отклонено';
        });
        return;
      }
    }

    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 2,
    );

    _positionStream =
        Geolocator.getPositionStream(locationSettings: locationSettings)
            .listen(_handleNewPosition);
  }

  void _handleNewPosition(Position position) {
    if (position.accuracy > _maxAcceptableAccuracy) return;

    final newPosition = LatLng(position.latitude, position.longitude);

    _recentPositions.add(newPosition);
    if (_recentPositions.length > _smoothingWindow) {
      _recentPositions.removeAt(0);
    }

    final avgLat =
        _recentPositions.map((p) => p.latitude).reduce((a, b) => a + b) /
            _recentPositions.length;
    final avgLng =
        _recentPositions.map((p) => p.longitude).reduce((a, b) => a + b) /
            _recentPositions.length;

    _animateToNewPosition(LatLng(avgLat, avgLng));
  }

  void _animateToNewPosition(LatLng newPosition) {
    final from = _displayedPosition ?? newPosition;

    _latAnim = Tween<double>(begin: from.latitude, end: newPosition.latitude)
        .animate(CurvedAnimation(parent: _animController, curve: Curves.linear));
    _lngAnim = Tween<double>(begin: from.longitude, end: newPosition.longitude)
        .animate(CurvedAnimation(parent: _animController, curve: Curves.linear));

    _animController.forward(from: 0);
    _latAnim!.addListener(_onAnimTick);
  }

  void _onAnimTick() {
    if (_latAnim == null || _lngAnim == null) return;

    final animated = LatLng(_latAnim!.value, _lngAnim!.value);

    setState(() {
      _displayedPosition = animated;
      _statusText = '';
    });

    if (_followMe) {
      _mapController.move(animated, _mapController.camera.zoom);
    }
  }

  String _getMapUrlTemplate() {
    switch (_mapStyle) {
      case 'light':
        return 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png';
      case 'google':
        return 'https://mt1.google.com/vt/lyrs=m&x={x}&y={y}&z={z}';
      case 'dark':
      default:
        return 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png';
    }
  }

  void _showSettingsBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        "Настройки отображения",
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white54),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white24),
                  const SizedBox(height: 10),
                  const Text("Стиль карты", style: TextStyle(color: Colors.white70, fontSize: 14)),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildStyleButton(setModalState, 'dark', 'Тёмная (Carto)'),
                      _buildStyleButton(setModalState, 'light', 'Светлая (Carto)'),
                      _buildStyleButton(setModalState, 'google', 'Google'),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("Калибровка стрелки", style: TextStyle(color: Colors.white70, fontSize: 14)),
                      Text(
                        "${_compassOffset >= 0 ? '+' : ''}${_compassOffset.toStringAsFixed(0)}°",
                        style: const TextStyle(color: Colors.blue, fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Slider(
                    value: _compassOffset,
                    min: -180.0,
                    max: 180.0,
                    divisions: 360,
                    activeColor: Colors.blue,
                    inactiveColor: Colors.white12,
                    onChanged: (value) {
                      setModalState(() {
                        _compassOffset = value;
                      });
                      setState(() {
                        _compassOffset = value;
                      });
                    },
                  ),
                  const Text(
                    "Отрегулируйте слайдер, если стрелка пилота косит влево или вправо.",
                    style: TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildStyleButton(StateSetter setModalState, String styleKey, String label) {
    bool isSelected = _mapStyle == styleKey;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4.0),
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: isSelected ? Colors.blue : Colors.white10,
            foregroundColor: isSelected ? Colors.white : Colors.white70,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: () {
            setModalState(() {
              _mapStyle = styleKey;
            });
            setState(() {
              _mapStyle = styleKey;
            });
          },
          child: Text(label, style: const TextStyle(fontSize: 11)),
        ),
      ),
    );
  }

  // НОВОЕ: открыть экран Bluetooth-настройки планера
  void _openBleConfigScreen() {
    // Сначала просим планер включить Bluetooth (через уже существующий канал:
    // телефон -> Wi-Fi/UDP -> земля -> LoRa -> воздух)
    _sendCommandToGlider("BLE_ON");

    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const BleConfigScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_displayedPosition == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(color: Colors.blue),
              const SizedBox(height: 16),
              Text(_statusText, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
            ],
          ),
        ),
      );
    }

    double distanceBetween = 0.0;
    if (_gliderPosition != null) {
      distanceBetween = Geolocator.distanceBetween(
        _displayedPosition!.latitude,
        _displayedPosition!.longitude,
        _gliderPosition!.latitude,
        _gliderPosition!.longitude,
      );
    }

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: _displayedPosition!,
            initialZoom: 16,
            onPositionChanged: (position, hasGesture) {
              if (hasGesture) {
                setState(() {
                  _followMe = false;
                });
              }
            },
          ),
          children: [
            TileLayer(
              urlTemplate: _getMapUrlTemplate(),
              subdomains: const ['a', 'b', 'c', 'd'],
            ),
            if (_gliderPosition != null)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: [_displayedPosition!, _gliderPosition!],
                    color: Colors.orange,
                    strokeWidth: 3.5,
                  ),
                ],
              ),
            MarkerLayer(
              markers: [
                Marker(
                  point: _displayedPosition!,
                  width: 50,
                  height: 50,
                  rotate: false,
                  child: AnimatedRotation(
                    turns: _displayRotation / 360,
                    duration: const Duration(milliseconds: 150),
                    curve: Curves.easeOut,
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.blue.withOpacity(0.25),
                        border: Border.all(color: Colors.blue, width: 2),
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.navigation,
                          color: Colors.blue,
                          size: 26,
                        ),
                      ),
                    ),
                  ),
                ),
                if (_gliderPosition != null)
                  Marker(
                    point: _gliderPosition!,
                    width: 50,
                    height: 50,
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.orange.withOpacity(0.3),
                        border: Border.all(color: Colors.orange, width: 2),
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.airplanemode_active,
                          color: Colors.orange,
                          size: 28,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),

        Positioned(
          top: 20,
          left: 20,
          child: Column(
            children: [
              FloatingActionButton(
                heroTag: "settings_btn",
                mini: true,
                backgroundColor: const Color(0xCC1A1A1A),
                foregroundColor: Colors.white,
                onPressed: _showSettingsBottomSheet,
                child: const Icon(Icons.settings),
              ),
              const SizedBox(height: 10),
              // НОВОЕ: кнопка Bluetooth-настройки планера
              FloatingActionButton(
                heroTag: "bluetooth_btn",
                mini: true,
                backgroundColor: const Color(0xCC1A1A1A),
                foregroundColor: Colors.blue,
                onPressed: _openBleConfigScreen,
                child: const Icon(Icons.bluetooth),
              ),
            ],
          ),
        ),

        Positioned(
          top: 20,
          right: 20,
          child: Column(
            children: [
              FloatingActionButton(
                heroTag: "rotate_mode_btn",
                mini: true,
                backgroundColor: _courseUp ? Colors.orange : const Color(0xCC1A1A1A),
                foregroundColor: Colors.white,
                onPressed: () {
                  setState(() {
                    _courseUp = !_courseUp;
                    if (!_courseUp) {
                      _mapController.rotate(0.0);
                    } else {
                      _mapController.rotate(-_heading);
                    }
                  });
                },
                child: Icon(_courseUp ? Icons.explore : Icons.explore_outlined),
              ),
              const SizedBox(height: 10),
              if (!_followMe)
                FloatingActionButton(
                  heroTag: "follow_btn",
                  mini: true,
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  onPressed: () {
                    setState(() {
                      _followMe = true;
                    });
                    _mapController.move(_displayedPosition!, 16);
                  },
                  child: const Icon(Icons.my_location),
                ),
            ],
          ),
        ),

        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              color: Color(0xED1A1A1A),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
              ),
              boxShadow: [
                BoxShadow(color: Colors.black54, blurRadius: 10, offset: Offset(0, -2))
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _gliderPosition != null ? Icons.wifi : Icons.wifi_off,
                          color: _gliderPosition != null ? Colors.green : Colors.red,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _gliderPosition != null ? "Планер на связи" : "Нет связи с планером",
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: _gliderPosition != null ? Colors.green : Colors.red,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        const Text("Тест-демо", style: TextStyle(fontSize: 12, color: Colors.white60)),
                        Switch(
                          value: _isSimulationActive,
                          activeColor: Colors.blue,
                          onChanged: _toggleSimulation,
                        ),
                      ],
                    )
                  ],
                ),
                const Divider(color: Colors.white24, height: 16),
                if (_gliderPosition != null) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildMetric(Icons.straighten, "Дистанция", "${distanceBetween.toStringAsFixed(1)} м"),
                      _buildMetric(Icons.cloud, "Высота", "${_gliderAlt.toStringAsFixed(1)} м"),
                      _buildMetric(Icons.gps_fixed, "Спутники", "$_gliderSats ${_gliderFix ? '(Fix)' : '(No Fix)'}"),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildMetric(Icons.grid_3x3, "Ускорение X", "${_gliderAccX.toStringAsFixed(2)} g"),
                      _buildMetric(Icons.grid_3x3, "Ускорение Y", "${_gliderAccY.toStringAsFixed(2)} g"),
                      _buildMetric(Icons.grid_3x3, "Ускорение Z", "${_gliderAccZ.toStringAsFixed(2)} g"),
                    ],
                  ),
                  const Divider(color: Colors.white24, height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        setState(() {
                          _gliderParaActive = !_gliderParaActive;
                        });
                        _sendCommandToGlider("PARA_TOGGLE");
                      },
                      icon: Icon(_gliderParaActive ? Icons.stop_circle : Icons.play_for_work),
                      label: Text(_gliderParaActive ? "СБРОСИТЬ ПАРАШЮТ (ЗАКРЫТЬ)" : "АКТИВИРОВАТЬ ПАРАШЮТ"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _gliderParaActive ? Colors.green : Colors.red,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                ] else ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Text(
                      "Подключитесь к Wi-Fi сети 'Glider_Ground_Station'\nили включите 'Тест-демо' для проверки",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white38, fontSize: 13),
                    ),
                  )
                ]
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMetric(IconData icon, String label, String value) {
    return Column(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.blueAccent),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(fontSize: 10, color: Colors.white54)),
          ],
        ),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
      ],
    );
  }
}

// ==================================================
// НОВОЕ: ЭКРАН BLUETOOTH-НАСТРОЙКИ ПЛАНЕРА
// ==================================================

class BleConfigScreen extends StatefulWidget {
  const BleConfigScreen({super.key});

  @override
  State<BleConfigScreen> createState() => _BleConfigScreenState();
}

class _BleConfigScreenState extends State<BleConfigScreen> {
  // UUID должны точно совпадать с теми, что заданы в коде планера
  static const String serviceUuid = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
  static const String charUuid = "beb5483e-36e1-4688-b7f5-ea07361b26a8";
  static const String deviceName = "GliderConfig";

  bool _isScanning = false;
  String _status = "Планеру отправлена команда на включение Bluetooth.\nНажмите «Найти планер», чтобы начать поиск.";

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _configCharacteristic;
  StreamSubscription<List<ScanResult>>? _scanSubscription;

  // Контроллеры полей формы - по одному на каждый параметр
  final Map<String, TextEditingController> _controllers = {
    "A": TextEditingController(),
    "StV": TextEditingController(),
    "StN": TextEditingController(),
    "StStart1": TextEditingController(),
    "StStart2": TextEditingController(),
    "KV": TextEditingController(),
    "KN": TextEditingController(),
    "KP": TextEditingController(),
    "KStart1": TextEditingController(),
    "KStart2": TextEditingController(),
    "KStart3": TextEditingController(),
    "BabV": TextEditingController(),
    "BabN": TextEditingController(),
    "BabPar": TextEditingController(),
    "KrZ": TextEditingController(),
    "KrO": TextEditingController(),
    "Time1": TextEditingController(),
    "Time2": TextEditingController(),
    "Time3": TextEditingController(),
    "Time4": TextEditingController(),
  };

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _connectedDevice?.disconnect();
    for (var c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _startScan() async {
    setState(() {
      _isScanning = true;
      _status = "Ищем планер по Bluetooth...";
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));

      _scanSubscription = FlutterBluePlus.scanResults.listen((results) async {
        for (ScanResult r in results) {
          if (r.device.platformName == deviceName) {
            await FlutterBluePlus.stopScan();
            _scanSubscription?.cancel();
            await _connectToDevice(r.device);
            return;
          }
        }
      });

      // Если за отведённое время устройство не нашлось
      Future.delayed(const Duration(seconds: 9), () {
        if (mounted && _connectedDevice == null) {
          setState(() {
            _isScanning = false;
            _status = "Планер не найден. Убедитесь, что вы рядом с ним "
                "и что прошло не больше 5 минут с момента включения Bluetooth. "
                "Попробуйте нажать «Найти планер» ещё раз.";
          });
        }
      });
    } catch (e) {
      setState(() {
        _isScanning = false;
        _status = "Ошибка поиска: $e";
      });
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    try {
      setState(() {
        _status = "Найден планер, подключаемся...";
      });

      await device.connect(timeout: const Duration(seconds: 10));
      _connectedDevice = device;

      List<BluetoothService> services = await device.discoverServices();
      for (var service in services) {
        if (service.uuid.toString().toLowerCase() == serviceUuid) {
          for (var characteristic in service.characteristics) {
            if (characteristic.uuid.toString().toLowerCase() == charUuid) {
              _configCharacteristic = characteristic;
            }
          }
        }
      }

      if (_configCharacteristic == null) {
        setState(() {
          _isScanning = false;
          _status = "Подключились, но не нашли нужную характеристику. "
              "Проверьте, что на планере залита актуальная прошивка.";
        });
        return;
      }

      await _readConfig();

      setState(() {
        _isScanning = false;
        _status = "Подключено! Можете менять параметры и сохранять.";
      });
    } catch (e) {
      setState(() {
        _isScanning = false;
        _status = "Ошибка подключения: $e";
      });
    }
  }

  Future<void> _readConfig() async {
    if (_configCharacteristic == null) return;
    try {
      List<int> value = await _configCharacteristic!.read();
      String jsonStr = utf8.decode(value);
      Map<String, dynamic> data = jsonDecode(jsonStr);

      data.forEach((key, value) {
        if (_controllers.containsKey(key)) {
          _controllers[key]!.text = value.toString();
        }
      });
    } catch (e) {
      setState(() {
        _status = "Ошибка чтения настроек: $e";
      });
    }
  }

  Future<void> _saveConfig() async {
    if (_configCharacteristic == null) {
      setState(() {
        _status = "Сначала нужно подключиться к планеру.";
      });
      return;
    }

    try {
      Map<String, dynamic> data = {};
      _controllers.forEach((key, controller) {
        final text = controller.text.trim();
        if (text.isNotEmpty) {
          // Поле "A" - дробное число, остальные - целые
          if (key == "A") {
            data[key] = double.tryParse(text) ?? 0.0;
          } else {
            data[key] = int.tryParse(text) ?? 0;
          }
        }
      });

      String jsonStr = jsonEncode(data);
      await _configCharacteristic!.write(utf8.encode(jsonStr), withoutResponse: false);

      setState(() {
        _status = "Настройки отправлены и сохранены на планере!";
      });
    } catch (e) {
      setState(() {
        _status = "Ошибка отправки настроек: $e";
      });
    }
  }

  Widget _buildField(String key, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: TextField(
        controller: _controllers[key],
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white60),
          enabledBorder: const OutlineInputBorder(
            borderSide: BorderSide(color: Colors.white24),
          ),
          focusedBorder: const OutlineInputBorder(
            borderSide: BorderSide(color: Colors.blue),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text("Настройка планера (Bluetooth)"),
        backgroundColor: const Color(0xFF1E1E1E),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              width: double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _status,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isScanning ? null : _startScan,
                icon: _isScanning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.bluetooth_searching),
                label: Text(_isScanning ? "Ищем..." : "Найти планер"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView(
                children: [
                  _buildField("A", "A (порог ускорения старта, g)"),
                  _buildField("StV", "StV (стабилизатор, крюк держит)"),
                  _buildField("StN", "StN (стабилизатор, нейтраль)"),
                  _buildField("StStart1", "StStart1"),
                  _buildField("StStart2", "StStart2"),
                  _buildField("KV", "KV (киль, крюк держит)"),
                  _buildField("KN", "KN (киль, нейтраль)"),
                  _buildField("KP", "KP (киль, полёт)"),
                  _buildField("KStart1", "KStart1"),
                  _buildField("KStart2", "KStart2"),
                  _buildField("KStart3", "KStart3"),
                  _buildField("BabV", "BabV (баббл, крюк держит)"),
                  _buildField("BabN", "BabN (баббл, нейтраль)"),
                  _buildField("BabPar", "BabPar (баббл, посадка)"),
                  _buildField("KrZ", "KrZ (крюк, закрыт)"),
                  _buildField("KrO", "KrO (крюк, открыт)"),
                  _buildField("Time1", "Time1 (мс)"),
                  _buildField("Time2", "Time2 (мс)"),
                  _buildField("Time3", "Time3 (мс)"),
                  _buildField("Time4", "Time4 (мс)"),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: _saveConfig,
                icon: const Icon(Icons.save),
                label: const Text("Сохранить на планере"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}