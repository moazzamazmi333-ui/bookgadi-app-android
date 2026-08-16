import 'dart:async';
import 'dart:math';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const BookGadiApp());
}

class BookGadiApp extends StatelessWidget {
  const BookGadiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BookGadi - Live Taxi Tracking & Online Cab Booking',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primaryColor: const Color(0xFF1A73E8),
        scaffoldBackgroundColor: const Color(0xFFF8F9FA),
        fontFamily: 'Segoe UI',
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
  // Google Maps & Firebase
  GoogleMapController? _mapController;
  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref('live_cars');
  StreamSubscription<DatabaseEvent>? _carsSubscription;

  // Controllers
  final TextEditingController _pickupController = TextEditingController();
  final TextEditingController _dropController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();

  // State Variables
  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};
  int _liveCarCount = 0;

  // Locations
  final LatLng _lko = const LatLng(26.8467, 80.9462);
  final LatLng _azm = const LatLng(26.0739, 83.1859);
  LatLng? _pickupLatLng;
  LatLng? _dropLatLng;

  // Pricing & Booking State
  bool _showResults = false;
  bool _showUserForm = false;
  String _selectedTripType = '';
  int _baseFareAmount = 0;
  int _singlePassengerFare = 0;
  int _totalDiscountCalculated = 0;
  int _passengerQty = 1;
  bool _payLater = false;

  DateTime _pickupDate = DateTime.now();
  TimeOfDay _pickupTime = TimeOfDay.now();
  File? _selectedFile;

  // Calculated Options
  double _calculatedKm = 0;
  String _calculatedTime = '';
  int _suvOneway = 0;
  int _suvRound = 0;
  int _fareAirportPickup = 0;
  int _fareAirportDrop = 0;

  @override
  void initState() {
    super.initState();
    _trackLiveCars();
    _useMyLocation();
  }

  @override
  void dispose() {
    _carsSubscription?.cancel();
    _pickupController.dispose();
    _dropController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  // Distance Calculation (Haversine Formula)
  double _getDistance(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLon = (lon2 - lon1) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) *
            cos(lat2 * pi / 180) *
            sin(dLon / 2) *
            sin(dLon / 2);
    return r * (2 * atan2(sqrt(a), sqrt(1 - a)));
  }

  // Realtime Database Tracking
  void _trackLiveCars() {
    _carsSubscription = _dbRef.onValue.listen((event) {
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data == null) return;

      Set<Marker> newMarkers = {};
      int count = 0;

      data.forEach((key, value) {
        if (value['status'] == 'online' &&
            value['lat'] != null &&
            value['lng'] != null) {
          count++;
          final double lat = double.parse(value['lat'].toString());
          final double lng = double.parse(value['lng'].toString());

          newMarkers.add(
            Marker(
              markerId: MarkerId(key.toString()),
              position: LatLng(lat, lng),
              infoWindow: InfoWindow(
                title: 'BookGadi Live Partner',
                snippet: 'Name: ${value['name'] ?? 'Available'} | Active Now',
              ),
              icon: BitmapDescriptor.defaultMarkerWithHue(
                  BitmapDescriptor.hueBlue),
            ),
          );
        }
      });

      setState(() {
        _markers = newMarkers;
        _liveCarCount = count;
      });
    });
  }

  // Location Functions
  Future<void> _useMyLocation() async {
    setState(() {
      _pickupController.text = "📍 Locating you... Please wait";
    });

    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _resetPickupText();
      _showSnackBar("Location services are disabled.");
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        _resetPickupText();
        _showSnackBar("Location permissions are denied.");
        return;
      }
    }

    Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high);
    _pickupLatLng = LatLng(position.latitude, position.longitude);

    try {
      List<Placemark> placemarks =
          await placemarkFromCoordinates(position.latitude, position.longitude);
      if (placemarks.isNotEmpty) {
        Placemark place = placemarks[0];
        String address =
            "${place.street}, ${place.subLocality}, ${place.locality}";
        setState(() {
          _pickupController.text = address;
        });
      }
    } catch (e) {
      _resetPickupText();
    }

    if (_mapController != null && _pickupLatLng != null) {
      _mapController!
          .animateCamera(CameraUpdate.newLatLngZoom(_pickupLatLng!, 12));
    }
  }

  void _resetPickupText() {
    setState(() {
      _pickupController.text = "";
    });
  }

  // Fare Calculation Engine
  Future<void> _calculateFare() async {
    if (_pickupController.text.isEmpty || _dropController.text.isEmpty) {
      _showSnackBar("Please enter correct locations");
      return;
    }

    try {
      List<Location> pickupLocs =
          await locationFromAddress(_pickupController.text);
      List<Location> dropLocs = await locationFromAddress(_dropController.text);

      if (pickupLocs.isEmpty || dropLocs.isEmpty) {
        _showSnackBar("Unable to find location coordinates.");
        return;
      }

      _pickupLatLng = LatLng(pickupLocs[0].latitude, pickupLocs[0].longitude);
      _dropLatLng = LatLng(dropLocs[0].latitude, dropLocs[0].longitude);

      double distFromAzm = _getDistance(_azm.latitude, _azm.longitude,
          _pickupLatLng!.latitude, _pickupLatLng!.longitude);
      double distFromLko = _getDistance(_lko.latitude, _lko.longitude,
          _pickupLatLng!.latitude, _pickupLatLng!.longitude);

      if (distFromAzm > 80 && distFromLko > 50) {
        _showDialog("Service Unavailable",
            "Maaf kijiye, BookGadi abhi keval Azamgarh (100km) aur Lucknow (50km) area mein hi pickup deti hai.");
        return;
      }

      // Estimate driving distance
      _calculatedKm = _getDistance(
              _pickupLatLng!.latitude,
              _pickupLatLng!.longitude,
              _dropLatLng!.latitude,
              _dropLatLng!.longitude) *
          1.25;
      _calculatedTime = "${(_calculatedKm * 2).round()} mins";

      // Rate Calculation logic
      _suvOneway = (250 + _calculatedKm * 13).round();
      _suvRound = (_calculatedKm * 12 * 2).round();

      int pickupRatePerKm = _calculatedKm > 235 ? 7 : 6;
      int dropRatePerKm = _calculatedKm > 235 ? 4 : 3;

      _fareAirportPickup = (200 + (_calculatedKm * pickupRatePerKm)).round();
      _fareAirportDrop = (50 + (_calculatedKm * dropRatePerKm)).round();

      // Draw Polyline
      setState(() {
        _polylines = {
          Polyline(
            polylineId: const PolylineId("route"),
            points: [_pickupLatLng!, _dropLatLng!],
            color: const Color(0xFF1A73E8),
            width: 5,
          )
        };
        _showResults = true;
        _showUserForm = false;
      });

      // Fit Camera to Route
      LatLngBounds bounds = LatLngBounds(
        southwest: LatLng(
          min<double>(_pickupLatLng!.latitude, _dropLatLng!.latitude),
          min<double>(_pickupLatLng!.longitude, _dropLatLng!.longitude),
        ),
        northeast: LatLng(
          max<double>(_pickupLatLng!.latitude, _dropLatLng!.latitude),
          max<double>(_pickupLatLng!.longitude, _dropLatLng!.longitude),
        ),
      );
      _mapController?.animateCamera(CameraUpdate.newLatLngBounds(bounds, 50));
    } catch (e) {
      _showSnackBar("Error processing route: $e");
    }
  }

  void _selectCard(String type, int amount, int manualDiscount) {
    setState(() {
      _selectedTripType = type;
      if (type.contains("Airport Shared Seat")) {
        _singlePassengerFare = amount;
        _passengerQty = 1;
        _baseFareAmount = _singlePassengerFare;
        _totalDiscountCalculated = 0;
      } else {
        _baseFareAmount = amount;
        _totalDiscountCalculated = manualDiscount;
      }
      _showUserForm = true;
    });
  }

  void _updateAirportFare(int qty) {
    setState(() {
      _passengerQty = qty;
      if (_selectedTripType.contains("Airport Shared Seat")) {
        int discountPerPerson = _selectedTripType.contains("PickUp") ? 200 : 50;
        if (qty > 1) {
          _totalDiscountCalculated = (qty - 1) * discountPerPerson;
        } else {
          _totalDiscountCalculated = 0;
        }
        _baseFareAmount = _singlePassengerFare * qty;
      }
    });
  }

  Future<void> _pickFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['pdf', 'jpg', 'png']);
    if (result != null && result.files.single.path != null) {
      setState(() {
        _selectedFile = File(result.files.single.path!);
      });
    }
  }

  int get netPayableAmount =>
      _baseFareAmount - _totalDiscountCalculated + (_payLater ? 300 : 0);

  Future<void> _startPayment() async {
    if (_nameController.text.isEmpty || _phoneController.text.length < 10) {
      _showSnackBar("Kripya sahi Naam aur 10-digit Mobile Number bharein.");
      return;
    }

    _showDialog("Booking Confirmed",
        "Booking Request Submitted Successfully!\nNet Payable: ₹$netPayableAmount");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: [
              _buildHeroSection(),
              _buildBadges(),
              _buildMapSection(),
              _buildFormSection(),
              if (_showResults) _buildFareResults(),
              if (_showUserForm) _buildBookingForm(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeroSection() {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFE8F0FE),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFDADCE0)),
      ),
      child: const Column(
        children: [
          Text("Online Taxi Booking with BookGadi",
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF202124))),
          SizedBox(height: 8),
          Text(
              "Welcome to BookGadi, your trusted partner for online taxi booking between Azamgarh, Lucknow, and surrounding areas.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Color(0xFF5F6368))),
        ],
      ),
    );
  }

  Widget _buildBadges() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
      color: const Color(0xFFE8F0FE),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          Text("🛡️ Safe Drivers",
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A73E8))),
          Text("💰 No Hidden Charges",
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A73E8))),
          Text("⚡ 24/7 Support",
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A73E8))),
        ],
      ),
    );
  }

  Widget _buildMapSection() {
    return Container(
      height: 350,
      margin: const EdgeInsets.symmetric(vertical: 10),
      child: Stack(
        children: [
          GoogleMap(
            initialCameraPosition:
                const CameraPosition(target: LatLng(26.5, 82.1), zoom: 8),
            onMapCreated: (controller) => _mapController = controller,
            markers: _markers,
            polylines: _polylines,
            zoomControlsEnabled: true,
          ),
          Positioned(
            top: 12,
            left: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.grey.shade300)),
              child: Row(
                children: [
                  Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                          color: Colors.green, shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                  Text("Live: $_liveCarCount",
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormSection() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          TextField(
              controller: _pickupController,
              decoration: const InputDecoration(
                  labelText: "Kahan se? (Pickup Location)",
                  border: OutlineInputBorder())),
          const SizedBox(height: 8),
          ElevatedButton.icon(
              onPressed: _useMyLocation,
              icon: const Icon(Icons.my_location),
              label: const Text("Current Location Use Karein")),
          const SizedBox(height: 8),
          TextField(
              controller: _dropController,
              decoration: const InputDecoration(
                  labelText: "Kahan tak? (Drop Location)",
                  border: OutlineInputBorder())),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: _calculateFare,
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF202124),
                minimumSize: const Size.fromHeight(50)),
            child: const Text("Kiraaya Dekhein",
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildFareResults() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              "Route: ${_calculatedKm.toStringAsFixed(1)} km | $_calculatedTime",
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 10),
          if (_calculatedKm <= 210) ...[
            _fareCard("🔄 SUV - Local Round Trip",
                (_calculatedKm * 16 * 2 + 100).round(), "card_suv_round", 0),
          ] else ...[
            _fareCard(
                "🚙 SUV - One Way Trip", _suvOneway, "card_suv_oneway", 0),
            _fareCard("🔄 SUV - Round Trip", _suvRound, "card_suv_round", 0),
            _fareCard("🛫 Airport Shared Seat PickUp", _fareAirportPickup,
                "card_airport_pickup", 200),
            _fareCard("🛫 Airport Shared Seat Drop", _fareAirportDrop,
                "card_airport_drop", 50),
          ],
        ],
      ),
    );
  }

  Widget _fareCard(String title, int amount, String id, int discount) {
    bool isSelected = _selectedTripType == title;
    return GestureDetector(
      onTap: () => _selectCard(title, amount, discount),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFE8F0FE) : Colors.white,
          border: Border.all(
              color:
                  isSelected ? const Color(0xFF1A73E8) : Colors.grey.shade300,
              width: 2),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13)),
                  Text("₹$amount",
                      style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1A73E8))),
                ],
              ),
            ),
            if (isSelected)
              const Icon(Icons.check_circle, color: Color(0xFF1A73E8)),
          ],
        ),
      ),
    );
  }

  Widget _buildBookingForm() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Booking Details Bharein:",
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 10),
          TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                  labelText: "Aapka Naam", border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                  labelText: "Mobile Number (10 digit)",
                  border: OutlineInputBorder())),
          const SizedBox(height: 10),
          if (_selectedTripType.contains("Airport Shared Seat")) ...[
            DropdownButtonFormField<int>(
              value: _passengerQty,
              decoration: const InputDecoration(
                  labelText: "Passengers Quantity",
                  border: OutlineInputBorder()),
              items: [1, 2, 3, 4]
                  .map((e) => DropdownMenuItem(
                      value: e, child: Text("$e Passenger(s)")))
                  .toList(),
              onChanged: (val) => _updateAirportFare(val!),
            ),
            const SizedBox(height: 10),
          ],
          Row(
            children: [
              Expanded(
                child: ListTile(
                  title: Text(DateFormat('yyyy-MM-dd').format(_pickupDate)),
                  trailing: const Icon(Icons.calendar_today),
                  onTap: () async {
                    DateTime? picked = await showDatePicker(
                        context: context,
                        initialDate: _pickupDate,
                        firstDate: DateTime.now(),
                        lastDate: DateTime(2030));
                    if (picked != null) setState(() => _pickupDate = picked);
                  },
                ),
              ),
              Expanded(
                child: ListTile(
                  title: Text(_pickupTime.format(context)),
                  trailing: const Icon(Icons.access_time),
                  onTap: () async {
                    TimeOfDay? picked = await showTimePicker(
                        context: context, initialTime: _pickupTime);
                    if (picked != null) setState(() => _pickupTime = picked);
                  },
                ),
              ),
            ],
          ),
          OutlinedButton.icon(
            onPressed: _pickFile,
            icon: const Icon(Icons.upload_file),
            label: Text(_selectedFile == null
                ? "Upload Ticket (Optional)"
                : "Ticket Selected"),
          ),
          CheckboxListTile(
            title: const Text("Book Now Pay Later (+ ₹300 Extra)",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            value: _payLater,
            onChanged: (val) => setState(() => _payLater = val!),
          ),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(10)),
            child: Column(
              children: [
                Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("Total Fare:"),
                      Text("₹$_baseFareAmount")
                    ]),
                Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("Discount:"),
                      Text("-₹$_totalDiscountCalculated",
                          style: const TextStyle(color: Colors.green))
                    ]),
                if (_payLater)
                  Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: const [Text("Pay Later Fee:"), Text("+₹300")]),
                const Divider(),
                Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("Net Payable:",
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      Text("₹$netPayableAmount",
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16))
                    ]),
              ],
            ),
          ),
          const SizedBox(height: 15),
          ElevatedButton(
            onPressed: _startPayment,
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF3395FF),
                minimumSize: const Size.fromHeight(50)),
            child: const Text("💳 Book & Pay Now",
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showSnackBar(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _showDialog(String title, String content) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(), child: const Text("OK"))
        ],
      ),
    );
  }
}
