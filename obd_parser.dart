class ObdParser {
  static String? parsePid(String command, String response) {
    final hex = _clean(response);
    final normalizedCommand = command.toUpperCase();
    final positive = '4${normalizedCommand.substring(1)}';
    final idx = hex.indexOf(positive);
    if (idx < 0) return null;
    final data = hex.substring(idx + positive.length);
    if (data.length < 2) return null;
    final a = int.tryParse(data.substring(0, 2), radix: 16);
    if (a == null) return null;
    switch (normalizedCommand) {
      case '010C':
        if (data.length < 4) return null;
        final b = int.tryParse(data.substring(2, 4), radix: 16);
        if (b == null) return null;
        return (((a * 256 + b) / 4).round()).toString();
      case '0105':
        return (a - 40).toString();
      case '0104':
      case '0111':
        return (a * 100 / 255).toStringAsFixed(1);
      case '0106':
      case '0107':
        return ((a - 128) * 100 / 128).toStringAsFixed(1);
      default:
        return null;
    }
  }

  static List<String> parseDtc(String response) {
    final hex = _clean(response);
    final idx = hex.indexOf('43');
    if (idx < 0) return [];
    final data = hex.substring(idx + 2);
    final result = <String>[];
    for (var i = 0; i + 4 <= data.length; i += 4) {
      final pair = data.substring(i, i + 4);
      if (pair == '0000' || pair == 'FFFF') continue;
      final b1 = int.tryParse(pair.substring(0, 2), radix: 16);
      final b2 = int.tryParse(pair.substring(2, 4), radix: 16);
      if (b1 == null || b2 == null) continue;
      const letters = ['P', 'C', 'B', 'U'];
      final first = letters[(b1 >> 6) & 0x03];
      final second = ((b1 >> 4) & 0x03).toString();
      final third = (b1 & 0x0F).toRadixString(16).toUpperCase();
      final tail = b2.toRadixString(16).padLeft(2, '0').toUpperCase();
      result.add('$first$second$third$tail');
    }
    return result.toSet().toList();
  }

  static String _clean(String input) => input.toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '');

  static String describeCode(String code) {
    switch (code.toUpperCase()) {
      case 'P0420':
        return 'Απόδοση καταλύτη κάτω από το όριο (Bank 1). Δεν αποδεικνύει μόνο του ότι χρειάζεται αλλαγή καταλύτη.';
      case 'P0030':
        return 'Κύκλωμα θέρμανσης αισθητήρα οξυγόνου, Bank 1 Sensor 1. Χρειάζεται έλεγχος αισθητήρα και καλωδίωσης.';
      default:
        return 'Κωδικός OBD-II. Χρειάζεται έλεγχος με βάση τα συμπτώματα και τις συνθήκες εμφάνισης.';
    }
  }
}
