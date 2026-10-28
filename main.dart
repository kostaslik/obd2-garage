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
