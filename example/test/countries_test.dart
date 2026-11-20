import 'package:flutter_test/flutter_test.dart';
import 'package:vobiz_webrtc_example/src/countries.dart';

/// The number splitting that decides which country code is dialled, and the
/// country picker's search.
void main() {
  group('splitE164', () {
    test('takes the longest calling code that matches', () {
      final samoa = splitE164('+16845551234')!;
      expect(samoa.country.dial, '+1684');
      expect(samoa.national, '5551234');
      final us = splitE164('+14155551234')!;
      expect(us.country.iso, 'US');
      expect(us.national, '4155551234');
    });

    test('a shared code keeps the selected country, else the one most callers mean', () {
      expect(splitE164('+447911123456')!.country.iso, 'GB');
      expect(splitE164('+447911123456', currentIso: 'GG')!.country.iso, 'GG');
      expect(splitE164('+14165551234', currentIso: 'CA')!.country.iso, 'CA');
    });

    test('ignores spaces, brackets and dashes', () {
      final split = splitE164('+44 (7911) 123-456')!;
      expect(split.country.iso, 'GB');
      expect(split.national, '7911123456');
    });

    test('is null without a plus, for a lone plus, and for a code no country has', () {
      expect(splitE164('919876543210'), isNull);
      expect(splitE164('+'), isNull);
      expect(splitE164('+0123'), isNull);
    });
  });

  group('searchCountries', () {
    test('finds a country by name, ISO code and calling code', () {
      expect(searchCountries('india').first.iso, 'IN');
      expect(searchCountries('IN').first.iso, 'IN');
      expect(searchCountries('91').first.iso, 'IN');
      expect(searchCountries('+91').first.iso, 'IN');
    });

    test('a shared calling code lists the country most callers mean first', () {
      expect(searchCountries('1').first.iso, 'US');
      expect(searchCountries('44').first.iso, 'GB');
    });

    test('an empty query lists every country; nonsense lists none', () {
      expect(searchCountries('  '), countries);
      expect(searchCountries('zzzz'), isEmpty);
    });
  });

  test('an unknown ISO code falls back to India', () {
    expect(findCountry('XX').iso, 'IN');
  });
}
