import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';

import 'obd_parser.dart';

void main() => runApp(const ObdApp());

class ObdApp extends StatelessWidget {
  const ObdApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'OBD2 Garage',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xFFE53935),
    brightness: Brightness.dark,
  ),
  scaffoldBackgroundColor: const Color(0xFF101114),
  cardTheme: CardThemeData(
    color: const Color(0xFF1B1D22),
    elevation: 2,
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: const BorderSide(color: Color(0xFF30323A)),
    ),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: Color(0xFF101114),
    foregroundColor: Colors.white,
    centerTitle: false,
  ),
  useMaterial3: true,
),
    home: const Dashboard(),
  );
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key});
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  BluetoothConnection? _connection;
  StreamSubscription<Uint8List>? _subscription;
  final List<int> _rxBuffer = [];
  final List<Map<String, String>> pids = [
    {'name': 'Στροφές κινητήρα', 'value': '—', 'unit': 'rpm', 'pid': '010C'},
    {'name': 'Θερμοκρασία ψυκτικού', 'value': '—', 'unit': '°C', 'pid': '0105'},
    {'name': 'Θερμοκρασία λαδιού', 'value': '—', 'unit': '°C', 'pid': '015C'},
    {'name': 'Φορτίο κινητήρα', 'value': '—', 'unit': '%', 'pid': '0104'},
    {'name': 'Θέση πεταλούδας', 'value': '—', 'unit': '%', 'pid': '0111'},
    {'name': 'STFT καυσίμου', 'value': '—', 'unit': '%', 'pid': '0106'},
    {'name': 'LTFT καυσίμου', 'value': '—', 'unit': '%', 'pid': '0107'},
  ];
  final List<String> codes = [];
  String status = 'Έτοιμο για σύνδεση';
  String rawResponse = '';
  String adapterInfo = 'Δεν έχει γίνει αναγνώριση';
  String protocolInfo = '—';
  bool busy = false;
  bool connected = false;
  bool live = false;
  bool demo = false;
  Timer? _pollTimer;
  Completer<String>? _responseCompleter;

  @override
  void dispose() {
    _pollTimer?.cancel();
    _subscription?.cancel();
    _connection?.dispose();
    super.dispose();
  }

  Future<bool> _ensurePermissions() async {
    if (!Platform.isAndroid) return false;
    final statuses = await [Permission.bluetoothConnect, Permission.bluetoothScan].request();
    return statuses.values.every((s) => s.isGranted);
  }

  Future<void> connectAdapter() async {
    if (!Platform.isAndroid) {
      setState(() => status = 'Το Bluetooth Classic SPP υποστηρίζεται εδώ μόνο στο Android. Για iPhone χρειάζεται ELM327 BLE ή Wi-Fi συμβατός.');
      return;
    }
    if (busy) return;
    setState(() { busy = true; status = 'Έλεγχος δικαιωμάτων Bluetooth…'; });
    try {
      final ok = await _ensurePermissions();
      if (!ok) throw Exception('Δεν δόθηκε άδεια Bluetooth. Έλεγξε τις άδειες της εφαρμογής.');
      final devices = await FlutterBluetoothSerial.instance.getBondedDevices();
      if (!mounted) return;
      final candidates = devices.where((d) {
        final n = (d.name ?? '').toLowerCase();
        return n.contains('obd') || n.contains('elm') || n.contains('vlink');
      }).toList();
      final all = devices;
      final selected = await showDialog<BluetoothDevice>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Επιλογή αντάπτορα'),
          content: SizedBox(width: double.maxFinite, child: ListView(
            shrinkWrap: true,
            children: (candidates.isNotEmpty ? candidates : all).map((d) => ListTile(
              leading: const Icon(Icons.bluetooth),
              title: Text(d.name ?? 'Άγνωστη συσκευή'),
              subtitle: Text(d.address),
              onTap: () => Navigator.pop(ctx, d),
            )).toList(),
          )),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Άκυρο'))],
        ),
      );
      if (selected == null) {
        setState(() => status = 'Δεν επιλέχθηκε αντάπτορας');
        return;
      }
      setState(() => status = 'Σύνδεση με ${selected.name ?? selected.address}…');
      final connection = await BluetoothConnection.toAddress(selected.address).timeout(const Duration(seconds: 12));
      _connection = connection;
      _subscription = connection.input?.listen(_onBytes, onError: (e) {
        if (mounted) setState(() { connected = false; live = false; status = 'Σφάλμα Bluetooth: $e'; });
      }, onDone: () {
        if (mounted) setState(() { connected = false; live = false; status = 'Η σύνδεση έκλεισε'; });
      });
      setState(() { connected = true; demo = false; status = 'Συνδέθηκε. Αρχικοποίηση ELM327…'; });
      await _initializeElm();
      if (!mounted) return;
      setState(() { busy = false; status = 'Συνδεδεμένο — έλεγχος αντάπτορα…'; });
      await identifyAdapter();
      if (!mounted) return;
      setState(() { busy = false; status = 'Συνδεδεμένο — βασικό OBD-II έτοιμο'; });
      await readTroubleCodes();
      await refreshPids();
      _startPolling();
    } catch (e) {
      if (mounted) setState(() { connected = false; live = false; status = 'Αποτυχία σύνδεσης: $e'; });
      await _connection?.dispose();
      _connection = null;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _onBytes(Uint8List data) {
    _rxBuffer.addAll(data);
    final text = ascii.decode(data, allowInvalid: true);
    rawResponse = (rawResponse + text);
    if (rawResponse.length > 4000) rawResponse = rawResponse.substring(rawResponse.length - 2000);
    if (rawResponse.contains('>')) {
      final response = rawResponse;
      rawResponse = '';
      final c = _responseCompleter;
      if (c != null && !c.isCompleted) c.complete(response);
    }
  }

  Future<String> _send(String command, {Duration timeout = const Duration(seconds: 4)}) async {
    final c = _connection;
    if (c == null || !c.isConnected) throw Exception('Δεν υπάρχει σύνδεση');
    final completer = Completer<String>();
    _responseCompleter = completer;
    c.output.add(ascii.encode('$command\r'));
    await c.output.allSent;
    try {
      return await completer.future.timeout(timeout);
    } finally {
      if (identical(_responseCompleter, completer)) _responseCompleter = null;
    }
  }

  Future<void> _initializeElm() async {
    for (final cmd in ['ATZ', 'ATE0', 'ATL0', 'ATS0', 'ATH0', 'ATSP0']) {
      try { await _send(cmd, timeout: const Duration(seconds: 5)); } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  String _cleanElmReply(String input) {
    return input.replaceAll('>', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Future<void> identifyAdapter() async {
    if (!connected || busy) return;
    setState(() => busy = true);
    try {
      String ati = 'Μη διαθέσιμο';
      String desc = 'Μη διαθέσιμο';
      String protocol = 'Μη διαθέσιμο';
      try { ati = _cleanElmReply(await _send('ATI', timeout: const Duration(seconds: 4))); } catch (_) {}
      try { desc = _cleanElmReply(await _send('AT@1', timeout: const Duration(seconds: 3))); } catch (_) {}
      try { protocol = _cleanElmReply(await _send('ATDP', timeout: const Duration(seconds: 3))); } catch (_) {}
      if (mounted) setState(() {
        adapterInfo = [ati, desc].where((v) => v != 'Μη διαθέσιμο' && v.isNotEmpty).join(' · ');
        if (adapterInfo.isEmpty) adapterInfo = 'Ο αντάπτορας δεν έδωσε αναγνωρίσιμη ταυτότητα';
        protocolInfo = protocol.isEmpty ? 'Μη διαθέσιμο' : protocol;
        status = 'Αναγνωρίστηκε η βασική σύνδεση OBD-II. Το coding μονάδων δεν έχει ενεργοποιηθεί.';
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> refreshPids() async {
    if (!connected || busy) return;
    setState(() => busy = true);
    try {
      final commands = ['010C', '0105', '015C', '0104', '0111', '0106', '0107'];
      for (var i = 0; i < commands.length; i++) {
        try {
          final response = await _send(commands[i], timeout: const Duration(seconds: 3));
          final value = ObdParser.parsePid(commands[i], response);
          if (value != null && mounted) {
            setState(() => pids[i]['value'] = value);
          } else if (commands[i] == '015C' && response.toUpperCase().contains('NO DATA') && mounted) {
            setState(() => pids[i]['value'] = 'N/A');
          }
        } catch (_) {}
      }
      if (mounted) setState(() { live = true; status = 'Συνδεδεμένο — ζωντανά δεδομένα'; });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (connected && !busy) refreshPids();
    });
  }

  Future<void> readTroubleCodes() async {
    if (!connected || busy) return;
    setState(() => busy = true);
    try {
      final response = await _send('03', timeout: const Duration(seconds: 6));
      final found = ObdParser.parseDtc(response);
      if (mounted) setState(() { codes..clear()..addAll(found); });
    } catch (e) {
      if (mounted) setState(() => status = 'Δεν διαβάστηκαν οι κωδικοί: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> clearTroubleCodes() async {
    if (!connected || busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Διαγραφή κωδικών βλάβης;'),
        content: const Text('Θα σταλεί η τυπική εντολή OBD-II Mode 04. Μπορεί να διαγραφούν αποθηκευμένοι κωδικοί και δεδομένα freeze-frame. Η διαγραφή δεν επισκευάζει την αιτία και δεν διαγράφει απαραίτητα σφάλματα φωτισμού από τη μονάδα αμαξώματος.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Άκυρο')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Διαγραφή')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => busy = true);
    try {
      final response = await _send('04', timeout: const Duration(seconds: 6));
      if (mounted) {
        setState(() {
          codes.clear();
          status = response.toUpperCase().contains('44')
              ? 'Η εντολή διαγραφής έγινε δεκτή. Κάνε νέα σάρωση.'
              : 'Στάλθηκε η εντολή διαγραφής. Απόκριση: ${response.trim()}';
        });
      }
    } catch (e) {
      if (mounted) setState(() => status = 'Αποτυχία διαγραφής κωδικών: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void showCodingInfo(String feature) {
    String details;
    if (feature == 'LED — προειδοποίηση καμένης λάμπας') {
      details = 'Διαθέσιμες ρυθμίσεις που μπορεί να υποστηρίζει το MINI R56, ανάλογα με τη μονάδα FRM και τον εξοπλισμό:

'
          '• Μεσαία/χαμηλή σκάλα (low beam)
'
          '• Μεγάλη σκάλα (high beam)
'
          '• Φώτα θέσης / Angel Eyes
'
          '• Μπροστινά και πίσω φλας
'
          '• Φώτα φρένων και τρίτο φως φρένων
'
          '• Φώτα ομίχλης, όπισθεν και πινακίδας

'
          'Η ακριβής λίστα εξαρτάται από FRM2 ή FRM3. Πρέπει πρώτα να αναγνωριστεί η μονάδα και να διαβαστεί/αποθηκευτεί η αρχική κωδικοποίηση. Το σημερινό ELM327 της εφαρμογής υποστηρίζει γενικό OBD-II και δεν μπορεί να γράψει αυτές τις ρυθμίσεις.';
    } else if (feature == 'Ηχητική υπενθύμιση ζώνης') {
      details = 'Στο R56 η σχετική ρύθμιση βρίσκεται στη μονάδα αερόσακων MRS6 και μπορεί να περιλαμβάνει:

'
          '• Αρχική ηχητική υπενθύμιση μετά την εκκίνηση
'
          '• Ηχητική/οπτική υπενθύμιση οδηγού
'
          '• Ηχητική/οπτική υπενθύμιση συνοδηγού

'
          'Δεν έχει επιβεβαιωθεί ακόμη ποια επιλογή είναι διαθέσιμη στη δική σου μονάδα. Η εφαρμογή δεν στέλνει αλλαγή με το ELM327. Για λόγους ασφάλειας, χρησιμοποίησε πάντα τη ζώνη.';
    } else {
      details = 'Πριν προστεθούν άλλες πραγματικές επιλογές coding, χρειάζεται αναγνώριση των μονάδων του αυτοκινήτου, συμβατός αντάπτορας και ασφαλής ανάγνωση/αποθήκευση των αρχικών ρυθμίσεων. Το απλό ELM327 που χρησιμοποιείται τώρα για γενικό OBD-II δεν αρκεί για να θεωρήσουμε ότι υποστηρίζει BMW/MINI coding.';
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(feature),
        content: SingleChildScrollView(child: Text('$details\n\nΚατάσταση: Πληροφορίες/προετοιμασία μόνο — η εγγραφή coding δεν είναι ακόμη ενεργή. Δεν θα εμφανιστεί ψεύτικη επιβεβαίωση αλλαγής.' )),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Εντάξει'))],
      ),
    );
  }

  Future<void> disconnect() async {
    _pollTimer?.cancel();
    await _subscription?.cancel();
    await _connection?.close();
    _connection = null;
    _subscription = null;
    if (mounted) setState(() { connected = false; live = false; status = 'Αποσυνδέθηκε'; });
  }

  void loadDemo() {
    _pollTimer?.cancel();
    setState(() {
      demo = true; connected = false; live = false; adapterInfo = 'Demo — όχι πραγματικός αντάπτορας'; protocolInfo = 'Demo';
      status = 'Λειτουργία επίδειξης — όχι πραγματικές μετρήσεις';
      pids[0]['value'] = '842'; pids[1]['value'] = '91';
      pids[2]['value'] = '103'; pids[3]['value'] = '18.4';
      pids[4]['value'] = '12.5'; pids[5]['value'] = '-1.6'; pids[6]['value'] = '2.3';
      codes..clear()..addAll(['P0420', 'P0030']);
    });
  }

  void clearData() {
    setState(() {
      demo = false; live = false; codes.clear(); adapterInfo = 'Δεν έχει γίνει αναγνώριση'; protocolInfo = '—';
      for (final p in pids) { p['value'] = '—'; }
      status = connected ? 'Συνδεδεμένο — αναμονή μετρήσεων' : 'Έτοιμο για σύνδεση';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Row(children: [Icon(Icons.directions_car_filled), SizedBox(width: 10), Text('OBD2 Garage')]),
        actions: [Padding(padding: const EdgeInsets.only(right: 16), child: Icon(connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled, color: connected ? Colors.greenAccent : Colors.white54))]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Icon(connected ? Icons.check_circle : Icons.info_outline), const SizedBox(width: 8), Expanded(child: Text(status, style: const TextStyle(fontWeight: FontWeight.w600)))]),
          const SizedBox(height: 8),
          const Text('Δοκιμαστική έκδοση • πραγματικές τιμές μόνο με ενεργή σύνδεση', style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(onPressed: busy ? null : connectAdapter, icon: const Icon(Icons.bluetooth_searching), label: const Text('Σύνδεση')),
            OutlinedButton.icon(onPressed: connected && !busy ? refreshPids : null, icon: const Icon(Icons.refresh), label: const Text('Ανανέωση')),
            OutlinedButton.icon(onPressed: connected && !busy ? identifyAdapter : null, icon: const Icon(Icons.memory), label: const Text('Έλεγχος αντάπτορα')),
            OutlinedButton.icon(onPressed: connected && !busy ? readTroubleCodes : null, icon: const Icon(Icons.document_scanner), label: const Text('Σάρωση DTC')),
            OutlinedButton.icon(onPressed: connected && !busy ? clearTroubleCodes : null, icon: const Icon(Icons.delete_sweep), label: const Text('Διαγραφή DTC')),
            OutlinedButton.icon(onPressed: connected ? disconnect : loadDemo, icon: Icon(connected ? Icons.link_off : Icons.play_arrow), label: Text(connected ? 'Αποσύνδεση' : 'Demo')),
          ]),
        ]))),
        const SizedBox(height: 10),
        Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('ΠΛΗΡΟΦΟΡΙΕΣ ΑΝΤΑΠΤΟΡΑ', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text('Ταυτότητα: $adapterInfo'),
          const SizedBox(height: 4),
          Text('Πρωτόκολλο OBD: $protocolInfo'),
          const SizedBox(height: 6),
          const Text('Αυτά τα στοιχεία βοηθούν στον έλεγχο του αντάπτορα, αλλά δεν αποδεικνύουν ότι υποστηρίζει εγγραφή coding σε FRM/MRS.', style: TextStyle(color: Colors.white60, fontSize: 12)),
        ]))),
        const SizedBox(height: 14),
        const Text('ΖΩΝΤΑΝΑ ΔΕΔΟΜΕΝΑ', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
        const SizedBox(height: 8),
        GridView.builder(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), itemCount: pids.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, childAspectRatio: 1.45, crossAxisSpacing: 10, mainAxisSpacing: 10),
          itemBuilder: (context, i) {
            final p = pids[i];
            return Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(p['name']!, style: const TextStyle(color: Colors.white70, fontSize: 12)),
              Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                Flexible(child: Text(p['value']!, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold))),
                const SizedBox(width: 5), Text(p['unit']!, style: const TextStyle(color: Colors.white60, fontSize: 11)),
              ]),
              Text('PID ${p['pid']}', style: const TextStyle(color: Colors.white38, fontSize: 10)),
            ])));
          }),
        const SizedBox(height: 18),
        Row(children: [const Expanded(child: Text('ΚΩΔΙΚΟΙ ΒΛΑΒΗΣ', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2))), Text('${codes.length} κωδικοί')]),
        const SizedBox(height: 8),
        if (codes.isEmpty) const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('Δεν έχουν διαβαστεί κωδικοί ή δεν υπάρχουν αποθηκευμένοι κωδικοί.')))
        else ...codes.map((code) => Card(child: ListTile(leading: const Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent), title: Text(code, style: const TextStyle(fontWeight: FontWeight.bold)), subtitle: Text(ObdParser.describeCode(code))))),
        const SizedBox(height: 18),
        const Text('CODING MINI R56', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
        const SizedBox(height: 8),
        const Text('Κατάλογος ειδικών ρυθμίσεων MINI. Οι επιλογές παρακάτω βασίζονται στις μονάδες FRM/MRS του R56, αλλά η εγγραφή παραμένει κλειδωμένη μέχρι να υποστηρίζεται και να αναγνωριστεί η μονάδα με συμβατό interface.', style: TextStyle(color: Colors.white60, fontSize: 12)),
        const SizedBox(height: 8),
        Card(child: ListTile(
          leading: const Icon(Icons.lightbulb_outline),
          title: const Text('LED — προειδοποιήσεις λαμπτήρων'),
          subtitle: const Text('FRM2/FRM3: μεσαία/μεγάλη σκάλα, θέσης, φλας, φρένα, ομίχλης, όπισθεν, πινακίδας'),
          trailing: const Icon(Icons.lock_outline),
          onTap: () => showCodingInfo('LED — προειδοποίηση καμένης λάμπας'),
        )),
        Card(child: ListTile(
          leading: const Icon(Icons.notifications_off_outlined),
          title: const Text('Υπενθύμιση ζώνης'),
          subtitle: const Text('MRS6: αρχική ειδοποίηση, οδηγός και συνοδηγός'),
          trailing: const Icon(Icons.lock_outline),
          onTap: () => showCodingInfo('Ηχητική υπενθύμιση ζώνης'),
        )),
        Card(child: ListTile(
          leading: const Icon(Icons.settings_suggest_outlined),
          title: const Text('Άλλες ρυθμίσεις coding'),
          subtitle: const Text('Θα εμφανίζονται μόνο όταν επιβεβαιωθεί η υποστήριξη'),
          trailing: const Icon(Icons.lock_outline),
          onTap: () => showCodingInfo('Άλλες ρυθμίσεις coding'),
        )),
        const SizedBox(height: 12),
        const Text('Σημείωση: το PID 015C είναι η τυπική εντολή θερμοκρασίας λαδιού· αν εμφανιστεί N/A, δεν επιστράφηκαν δεδομένα. Η διαγραφή DTC αφορά γενικούς κωδικούς OBD-II και δεν διαγράφει απαραίτητα σφάλματα φωτισμού της μονάδας FRM. Το πραγματικό coding MINI και η σύνδεση iPhone δεν έχουν υλοποιηθεί ακόμη. Το κουμπί «Έλεγχος αντάπτορα» διαβάζει ATI/AT@1/ATDP για να βοηθήσει στην αναγνώριση της συσκευής, αλλά δεν αποτελεί δοκιμή δυνατότητας coding.', style: TextStyle(color: Colors.white60, fontSize: 12)),
      ]),
    );
  }
}
  // =========================
  // PART 3: DASHBOARD & UI
  // =========================

  String _displayValue(String key, String unit) {
    final value = _values[key];
    if (value == null) return '-- $unit';
    return '$value $unit';
  }

  Widget _sectionTitle(String title, {String? subtitle}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(
                color: Colors.grey.shade400,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _metricCard({
    required String title,
    required String value,
    required IconData icon,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.redAccent, size: 24),
            const SizedBox(height: 12),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: const TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              style: TextStyle(
                color: Colors.grey.shade300,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rpmGauge() {
    final rpm = double.tryParse(
          (_values['rpm'] ?? '0').toString(),
        ) ??
        0.0;

    final progress = (rpm / 7000).clamp(0.0, 1.0);

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: 22,
          horizontal: 16,
        ),
        child: Column(
          children: [
            const Text(
              'ENGINE RPM',
              style: TextStyle(
                color: Colors.grey,
                fontSize: 12,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: 210,
              height: 210,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 200,
                    height: 200,
                    child: CircularProgressIndicator(
                      value: progress,
                      strokeWidth: 13,
                      backgroundColor: Colors.white12,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        rpm >= 5500
                            ? Colors.red
                            : Colors.redAccent,
                      ),
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        rpm.round().toString(),
                        style: const TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Text(
                        'RPM',
                        style: TextStyle(
                          color: Colors.grey,
                          letterSpacing: 2,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _connection == null
                  ? 'Waiting for OBD connection'
                  : 'Live engine speed',
              style: TextStyle(
                color: Colors.grey.shade400,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _connectionCard() {
    final connected = _connection != null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(
              connected
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth,
              color: connected
                  ? Colors.greenAccent
                  : Colors.orangeAccent,
              size: 28,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    connected
                        ? 'OBD adapter connected'
                        : _status,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _deviceName.isNotEmpty
                        ? _deviceName
                        : 'Bluetooth ELM327',
                    style: TextStyle(
                      color: Colors.grey.shade400,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: connected ? 'Disconnect' : 'Connect',
              onPressed: connected
                  ? () => _disconnect()
                  : _chooseAdapter,
              icon: Icon(
                connected
                    ? Icons.link_off
                    : Icons.bluetooth_searching,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sportPage() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _connectionCard(),
        _rpmGauge(),
        _sectionTitle(
          'LIVE ENGINE DATA',
          subtitle: 'Real-time στοιχεία κινητήρα',
        ),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 1.35,
          children: [
            _metricCard(
              title: 'Coolant temperature',
              value: _displayValue('coolant', '°C'),
              icon: Icons.thermostat,
            ),
            _metricCard(
              title: 'Oil temperature',
              value: _displayValue('oilTemp', '°C'),
              icon: Icons.oil_barrel_outlined,
            ),
            _metricCard(
              title: 'Engine load',
              value: _displayValue('load', '%'),
              icon: Icons.speed,
            ),
            _metricCard(
              title: 'Throttle position',
              value: _displayValue('throttle', '%'),
              icon: Icons.flash_on,
            ),
            _metricCard(
              title: 'Short fuel trim',
              value: _displayValue('stft', '%'),
              icon: Icons.tune,
            ),
            _metricCard(
              title: 'Long fuel trim',
              value: _displayValue('ltft', '%'),
              icon: Icons.analytics_outlined,
            ),
          ],
        ),
        _sectionTitle('QUICK ACTIONS'),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _connection == null
                    ? _chooseAdapter
                    : _refreshPids,
                icon: Icon(
                  _connection == null
                      ? Icons.bluetooth_searching
                      : Icons.refresh,
                ),
                label: Text(
                  _connection == null
                      ? 'Connect OBD'
                      : 'Refresh data',
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _identifyAdapter,
                icon: const Icon(Icons.info_outline),
                label: const Text('Adapter info'),
              ),
            ),
          ],
        ),
        _sectionTitle('RECENT ACTIVITY'),
        if (_history.isEmpty)
          const Card(
            child: ListTile(
              leading: Icon(Icons.history),
              title: Text('No activity yet'),
              subtitle: Text('Οι ενέργειες θα εμφανιστούν εδώ.'),
            ),
          )
        else
          ..._history.take(8).map(
            (entry) => Card(
              child: ListTile(
                dense: true,
                leading: const Icon(
                  Icons.circle,
                  size: 9,
                  color: Colors.redAccent,
                ),
                title: Text(entry.toString()),
              ),
            ),
          ),
      ],
    );
  }

  Widget _diagnosticsPage() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _connectionCard(),
        _sectionTitle(
          'DIAGNOSTICS',
          subtitle: 'Engine fault codes and live data',
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.car_repair,
                      color: Colors.redAccent,
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Engine fault codes',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _dtcMessage.isNotEmpty
                      ? _dtcMessage
                      : 'Read available ECU trouble codes.',
                  style: TextStyle(
                    color: Colors.grey.shade400,
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _connection == null
                            ? null
                            : _readTroubleCodes,
                        icon: const Icon(Icons.search),
                        label: const Text('Read codes'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _connection == null
                            ? null
                            : _clearTroubleCodes,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Clear codes'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        _sectionTitle('STORED FAULTS'),
        if (_dtcs.isEmpty)
          const Card(
            child: ListTile(
              leading: Icon(
                Icons.info_outline,
                color: Colors.orangeAccent,
              ),
              title: Text('No codes displayed'),
              subtitle: Text(
                'Δεν έχουν εμφανιστεί κωδικοί. '
                'Αυτό δεν επιβεβαιώνει ότι δεν υπάρχουν βλάβες.',
              ),
            ),
          )
        else
          ..._dtcs.map(
            (code) => Card(
              child: ListTile(
                leading: const Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.orangeAccent,
                ),
                title: Text(
                  code.toString(),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                subtitle: const Text('ECU diagnostic trouble code'),
              ),
            ),
          ),
        _sectionTitle('LIVE DATA'),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.speed),
                title: const Text('Engine RPM'),
                trailing: Text(_displayValue('rpm', 'rpm')),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.thermostat),
                title: const Text('Coolant temperature'),
                trailing: Text(_displayValue('coolant', '°C')),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.flash_on),
                title: const Text('Throttle position'),
                trailing: Text(_displayValue('throttle', '%')),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.tune),
                title: const Text('Short fuel trim'),
                trailing: Text(_displayValue('stft', '%')),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.analytics_outlined),
                title: const Text('Long fuel trim'),
                trailing: Text(_displayValue('ltft', '%')),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _factoryPage() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _connectionCard(),
        _sectionTitle(
          'MINI FACTORY',
          subtitle: 'MINI Cooper R56 · 2007',
        ),
        Card(
          child: Column(
            children: [
              const ListTile(
                leading: Icon(
                  Icons.directions_car,
                  color: Colors.redAccent,
                ),
                title: Text('MINI Cooper R56'),
                subtitle: Text('2007 · N12B16A · 1.6 petrol'),
              ),
              const Divider(height: 1),
              const ListTile(
                leading: Icon(Icons.memory),
                title: Text('Engine family'),
                subtitle: Text('Prince / PSA-BMW N12'),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.bluetooth),
                title: const Text('Adapter information'),
                subtitle: Text(_deviceName.isEmpty
                    ? 'Bluetooth ELM327'
                    : _deviceName),
                trailing: const Icon(Icons.info_outline),
                onTap: _identifyAdapter,
              ),
            ],
          ),
        ),
        _sectionTitle('CODING & ADAPTATIONS'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.settings_suggest,
                  color: Colors.redAccent,
                  size: 30,
                ),
                const SizedBox(height: 10),
                const Text(
                  'MINI coding information',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Οι πραγματικές αλλαγές στις μονάδες BMW/MINI '
                  'δεν είναι ακόμη ενεργές. Απαιτούνται κατάλληλο '
                  'interface και υποστήριξη των αντίστοιχων μονάδων.',
                  style: TextStyle(
                    color: Colors.grey.shade400,
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _showFactoryInfo,
                  icon: const Icon(Icons.info_outline),
                  label: const Text('More information'),
                ),
              ],
            ),
          ),
        ),
        _sectionTitle('AVAILABLE INFORMATION'),
        const Card(
          child: ListTile(
            leading: Icon(Icons.lightbulb_outline),
            title: Text('LED lighting coding'),
            subtitle: Text(
              'Πληροφορίες συμβατότητας FRM — '
              'δεν εκτελείται εγγραφή ρυθμίσεων.',
            ),
          ),
        ),
        const Card(
          child: ListTile(
            leading: Icon(Icons.notifications_off_outlined),
            title: Text('Seat-belt reminder'),
            subtitle: Text(
              'Πληροφορίες μονάδας MRS — '
              'δεν εκτελείται αλλαγή ρυθμίσεων.',
            ),
          ),
        ),
      ],
    );
  }

  Widget _servicePage() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _connectionCard(),
        _sectionTitle(
          'SERVICE CENTER',
          subtitle: 'Maintenance and diagnostic tools',
        ),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(
                  Icons.monitor_heart_outlined,
                  color: Colors.redAccent,
                ),
                title: const Text('Live engine data'),
                subtitle: const Text(
                  'Παρακολούθηση διαθέσιμων αισθητήρων.',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  setState(() => _selectedTab = 0);
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(
                  Icons.car_repair,
                  color: Colors.redAccent,
                ),
                title: const Text('Diagnostic trouble codes'),
                subtitle: const Text(
                  'Ανάγνωση και διαγραφή γενικών OBD-II DTC.',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  setState(() => _selectedTab = 1);
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(
                  Icons.settings_suggest,
                  color: Colors.redAccent,
                ),
                title: const Text('MINI Factory'),
                subtitle: const Text(
                  'Πληροφορίες για τις εργοστασιακές μονάδες.',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  setState(() => _selectedTab = 2);
                },
              ),
            ],
          ),
        ),
        _sectionTitle('DEMO MODE'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.play_circle_outline,
                  color: Colors.redAccent,
                  size: 30,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Try the dashboard',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Η επίδειξη χρησιμοποιεί ενδεικτικές τιμές '
                  'και δεν αποτελεί πραγματική μέτρηση.',
                  style: TextStyle(
                    color: Colors.grey.shade400,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _loadDemo,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Start demo'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _clearDemo,
                        icon: const Icon(Icons.restart_alt),
                        label: const Text('Reset demo'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        _sectionTitle('CONNECTION STATUS'),
        Card(
          child: ListTile(
            leading: Icon(
              _connection == null
                  ? Icons.bluetooth_disabled
                  : Icons.bluetooth_connected,
              color: _connection == null
                  ? Colors.orangeAccent
                  : Colors.greenAccent,
            ),
            title: Text(_status),
            subtitle: Text(
              _deviceAddress.isEmpty
                  ? 'Δεν έχει επιλεγεί διεύθυνση αντάπτορα.'
                  : _deviceAddress,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      _sportPage(),
      _diagnosticsPage(),
      _factoryPage(),
      _servicePage(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.directions_car_filled),
            SizedBox(width: 10),
            Text('OBD Garage R56'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh live data',
            onPressed: _connection == null ? null : _refreshPids,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Connect adapter',
            onPressed: _connection == null
                ? _chooseAdapter
                : () => _disconnect(),
            icon: Icon(
              _connection == null
                  ? Icons.bluetooth_searching
                  : Icons.link_off,
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: IndexedStack(
        index: _selectedTab,
        children: pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedTab,
        onDestinationSelected: (index) {
          setState(() => _selectedTab = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.speed_outlined),
            selectedIcon: Icon(Icons.speed),
            label: 'Sport',
          ),
          NavigationDestination(
            icon: Icon(Icons.car_repair_outlined),
            selectedIcon: Icon(Icons.car_repair),
            label: 'Diagnostics',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_suggest_outlined),
            selectedIcon: Icon(Icons.settings_suggest),
            label: 'MINI Factory',
          ),
          NavigationDestination(
            icon: Icon(Icons.build_outlined),
            selectedIcon: Icon(Icons.build),
            label: 'Service',
          ),
        ],
      ),
    );
  }
}
