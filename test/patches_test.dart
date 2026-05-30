import 'package:ntr/ntr.dart';
import 'package:test/test.dart';

void main() {
  group('Patches.universal', () {
    test('targets pid 0x1a at offset 0x105ae4 with two ARM Thumb bytes', () {
      final patch = Patches.universal;

      expect(patch.pid, 0x1a);
      expect(patch.processName, isNull);
      expect(patch.offset, 0x105ae4);
      expect(patch.bytes, <int>[0x70, 0x47]);
    });
  });

  group('Patches.pokemonSunMoon', () {
    test('targets process niji_loc at offset 0x3e14c0', () {
      final patch = Patches.pokemonSunMoon;

      expect(patch.pid, isNull);
      expect(patch.processName, 'niji_loc');
      expect(patch.offset, 0x3e14c0);
      expect(patch.bytes, <int>[0xe3, 0xa0, 0x10, 0x00]);
    });
  });

  group('findPidByName', () {
    test('extracts the pid from a single matching line', () {
      const payload =
          'pid: 0000001a, pname:    niji_loc\npid: 00000002, pname:    other';

      expect(findPidByName(payload, 'niji_loc'), 0x1a);
    });

    test('returns null when no line matches', () {
      const payload = 'pid: 0000001a, pname:    other_proc';

      expect(findPidByName(payload, 'niji_loc'), isNull);
    });
  });
}
