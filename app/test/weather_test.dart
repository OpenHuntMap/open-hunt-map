import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/weather/activity.dart';
import 'package:open_woods_map/weather/weather.dart';

/// Builds an Open-Meteo shaped payload for one day so the parser and the
/// heuristic can be exercised without a network call.
Map<String, dynamic> payload({
  required String date,
  double temperature = 10,
  double windSpeed = 10,
  double windGusts = 15,
  double pressure = 1015,
  double precipitation = 0,
  int weatherCode = 0,
  String sunrise = '07:00',
  String sunset = '17:00',
  Map<int, double>? temperatureByHour,
  Map<int, double>? windByHour,
  Map<int, double>? pressureByHour,
}) {
  final times = <String>[];
  final temps = <double>[];
  final winds = <double>[];
  final pressures = <double>[];
  for (var hour = 0; hour < 24; hour++) {
    times.add('${date}T${hour.toString().padLeft(2, '0')}:00');
    temps.add(temperatureByHour?[hour] ?? temperature);
    winds.add(windByHour?[hour] ?? windSpeed);
    pressures.add(pressureByHour?[hour] ?? pressure);
  }
  return {
    'latitude': 45.1,
    'longitude': -75.75,
    'utc_offset_seconds': -14400,
    'current': {
      'time': '${date}T12:00',
      'temperature_2m': temperature,
      'relative_humidity_2m': 60,
      'precipitation': precipitation,
      'weather_code': weatherCode,
      'cloud_cover': 40,
      'pressure_msl': pressure,
      'wind_speed_10m': windSpeed,
      'wind_direction_10m': 270,
      'wind_gusts_10m': windGusts,
    },
    'hourly': {
      'time': times,
      'temperature_2m': temps,
      'precipitation_probability': List.filled(24, 10),
      'precipitation': List.filled(24, precipitation),
      'weather_code': List.filled(24, weatherCode),
      'cloud_cover': List.filled(24, 40),
      'pressure_msl': pressures,
      'wind_speed_10m': winds,
      'wind_direction_10m': List.filled(24, 270),
      'wind_gusts_10m': List.filled(24, windGusts),
    },
    'daily': {
      'time': [date],
      'weather_code': [weatherCode],
      'temperature_2m_max': [temperature + 4],
      'temperature_2m_min': [temperature - 4],
      'precipitation_sum': [precipitation * 24],
      'precipitation_probability_max': [20],
      'wind_speed_10m_max': [windSpeed],
      'wind_direction_10m_dominant': [270],
      'sunrise': ['${date}T$sunrise'],
      'sunset': ['${date}T$sunset'],
    },
  };
}

void main() {
  group('parseWeather', () {
    test('reads current conditions, 24 hours and the daily entry', () {
      final report = parseWeather(payload(date: '2026-11-15'));

      expect(report.hourly, hasLength(24));
      expect(report.daily, hasLength(1));
      expect(report.current.temperature, 10);
      expect(report.current.windDirection, 270);
      expect(report.utcOffset, const Duration(hours: -4));
      expect(report.latitude, closeTo(45.1, 0.001));
    });

    test('derives legal light as a half hour either side of the sun', () {
      final report = parseWeather(payload(date: '2026-11-15'));
      final day = report.daily.single;

      expect(day.sunrise.hour, 7);
      expect(day.legalStart.hour, 6);
      expect(day.legalStart.minute, 30);
      expect(day.legalEnd.hour, 17);
      expect(day.legalEnd.minute, 30);
    });

    test('rejects a response missing its blocks', () {
      expect(
        () => parseWeather({'latitude': 45.0}),
        throwsA(isA<WeatherUnavailable>()),
      );
    });

    test('hoursOn only returns the requested day', () {
      final report = parseWeather(payload(date: '2026-11-15'));
      expect(report.hoursOn(DateTime(2026, 11, 15)), hasLength(24));
      expect(report.hoursOn(DateTime(2026, 11, 16)), isEmpty);
    });
  });

  group('windCompass', () {
    test('maps bearings to compass points and wraps at north', () {
      expect(windCompass(0), 'N');
      expect(windCompass(90), 'E');
      expect(windCompass(180), 'S');
      expect(windCompass(270), 'W');
      expect(windCompass(360), 'N');
      expect(windCompass(354), 'N');
      expect(windCompass(45), 'NE');
    });
  });

  group('weatherDescription', () {
    test('names known codes and degrades gracefully', () {
      expect(weatherDescription(0), 'Clear');
      expect(weatherDescription(65), 'Heavy rain');
      expect(weatherDescription(95), 'Thunderstorm');
      expect(weatherDescription(-1), 'Unknown');
    });
  });

  group('DeerActivity', () {
    DeerActivity rate(Map<String, dynamic> json) {
      final report = parseWeather(json);
      return DeerActivity.forDay(report, report.daily.single);
    }

    test('rates the light at each end of the day above the midday lull', () {
      final activity = rate(payload(date: '2026-11-15'));
      final dawn = activity.hours.firstWhere((hour) => hour.time.hour == 7);
      final dusk = activity.hours.firstWhere((hour) => hour.time.hour == 17);
      final midday = activity.hours.firstWhere((hour) => hour.time.hour == 12);

      expect(dawn.score, greaterThan(midday.score));
      expect(dusk.score, greaterThan(midday.score));
    });

    test('flags legal light only between the half-hour bounds', () {
      final activity = rate(payload(date: '2026-11-15'));
      bool legalAt(int hour) =>
          activity.hours.firstWhere((entry) => entry.time.hour == hour)
              .legalLight;

      expect(legalAt(5), isFalse);
      expect(legalAt(7), isTrue);
      expect(legalAt(17), isTrue);
      expect(legalAt(18), isFalse);
    });

    test('penalises strong wind', () {
      final calm = rate(payload(date: '2026-11-15', windSpeed: 10));
      final gale = rate(payload(date: '2026-11-15', windSpeed: 40));
      int dawn(DeerActivity activity) => activity.hours
          .firstWhere((hour) => hour.time.hour == 7)
          .score;

      expect(dawn(gale), lessThan(dawn(calm)));
      expect(
        gale.hours
            .firstWhere((hour) => hour.time.hour == 7)
            .factors
            .map((factor) => factor.label),
        contains('Very strong wind'),
      );
    });

    test('penalises a thunderstorm', () {
      final clear = rate(payload(date: '2026-11-15'));
      final storm = rate(payload(date: '2026-11-15', weatherCode: 95));
      int dawn(DeerActivity a) =>
          a.hours.firstWhere((hour) => hour.time.hour == 7).score;

      expect(dawn(storm), lessThan(dawn(clear)));
    });

    test('adds a rut bonus in November but not in September', () {
      int middayFor(String date) => rate(payload(date: date))
          .hours
          .firstWhere((hour) => hour.time.hour == 12)
          .score;

      expect(middayFor('2026-11-15'), greaterThan(middayFor('2026-09-15')));
      expect(
        rate(payload(date: '2026-11-15'))
            .hours
            .firstWhere((hour) => hour.time.hour == 12)
            .factors
            .map((factor) => factor.label),
        contains('Peak rut'),
      );
    });

    test('rewards an hour colder than the rest of the forecast', () {
      final activity = rate(
        payload(
          date: '2026-11-15',
          temperature: 10,
          // A single cold hour against a mild day.
          temperatureByHour: {7: 1},
        ),
      );
      final labels = activity.hours
          .firstWhere((hour) => hour.time.hour == 7)
          .factors
          .map((factor) => factor.label);

      expect(labels, contains('Well below normal temp'));
    });

    test('reads a pressure rise over the preceding three hours', () {
      final activity = rate(
        payload(
          date: '2026-11-15',
          pressureByHour: {4: 1000, 5: 1002, 6: 1004, 7: 1008},
        ),
      );
      final labels = activity.hours
          .firstWhere((hour) => hour.time.hour == 7)
          .factors
          .map((factor) => factor.label);

      expect(labels, contains('Pressure rising behind a front'));
    });

    test('keeps every suggested window inside legal light', () {
      final activity = rate(payload(date: '2026-11-15'));
      final day = parseWeather(payload(date: '2026-11-15')).daily.single;

      expect(activity.windows, isNotEmpty);
      for (final window in activity.windows) {
        expect(window.start.isBefore(day.legalStart), isFalse);
        expect(window.end.isAfter(day.legalEnd.add(const Duration(hours: 1))),
            isFalse);
      }
    });

    test('orders windows by peak score', () {
      final activity = rate(payload(date: '2026-11-15'));
      final scores = activity.windows.map((window) => window.peakScore).toList();
      final sorted = [...scores]..sort((a, b) => b.compareTo(a));

      expect(scores, sorted);
    });

    test('keeps scores inside 0-100 under stacked penalties', () {
      final activity = rate(
        payload(
          date: '2026-07-15',
          windSpeed: 60,
          windGusts: 90,
          precipitation: 20,
          weatherCode: 95,
        ),
      );
      for (final hour in activity.hours) {
        expect(hour.score, inInclusiveRange(0, 100));
      }
    });
  });
}
