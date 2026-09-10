/// Open-Meteo client and models.
///
/// Open-Meteo needs no API key and no sign-up, which is why it fits an app with
/// no backend and no budget. Its free tier is non-commercial only and its data
/// is CC BY 4.0, so the attribution in [openMeteoAttribution] has to stay
/// visible wherever weather is shown.
///
/// All timestamps are wall-clock at the queried point, not at the device. The
/// API is asked for `timezone=auto` and returns naive local strings; [now] is
/// built the same way from [utcOffset] so comparisons stay coherent even when
/// the user is in a different timezone than the pin.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

const openMeteoAttribution = 'Weather data by Open-Meteo.com (CC BY 4.0)';
const openMeteoUrl = 'https://open-meteo.com/';

class WeatherUnavailable implements Exception {
  const WeatherUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Conditions for a single hour at a point.
class HourConditions {
  const HourConditions({
    required this.time,
    required this.temperature,
    required this.windSpeed,
    required this.windDirection,
    required this.windGusts,
    required this.pressure,
    required this.precipitation,
    required this.precipitationChance,
    required this.cloudCover,
    required this.weatherCode,
  });

  /// Wall-clock time at the queried point.
  final DateTime time;
  final double temperature;
  final double windSpeed;
  final int windDirection;
  final double windGusts;
  final double pressure;
  final double precipitation;
  final int precipitationChance;
  final int cloudCover;
  final int weatherCode;
}

class DayForecast {
  const DayForecast({
    required this.date,
    required this.high,
    required this.low,
    required this.precipitationSum,
    required this.precipitationChance,
    required this.maxWind,
    required this.dominantWindDirection,
    required this.weatherCode,
    required this.sunrise,
    required this.sunset,
  });

  final DateTime date;
  final double high;
  final double low;
  final double precipitationSum;
  final int precipitationChance;
  final double maxWind;
  final int dominantWindDirection;
  final int weatherCode;
  final DateTime sunrise;
  final DateTime sunset;

  /// Ontario and Quebec both set legal light for big game at a half hour either
  /// side of the sun. Species exceptions exist (raccoon at night, for one), so
  /// this is shown as guidance rather than as the rule for every tag.
  DateTime get legalStart => sunrise.subtract(const Duration(minutes: 30));
  DateTime get legalEnd => sunset.add(const Duration(minutes: 30));
}

class WeatherReport {
  const WeatherReport({
    required this.latitude,
    required this.longitude,
    required this.utcOffset,
    required this.current,
    required this.hourly,
    required this.daily,
    required this.fetchedAt,
  });

  final double latitude;
  final double longitude;
  final Duration utcOffset;
  final HourConditions current;
  final List<HourConditions> hourly;
  final List<DayForecast> daily;
  final DateTime fetchedAt;

  /// Wall-clock "now" at the queried point.
  DateTime get now => DateTime.now().toUtc().add(utcOffset);

  DayForecast? get today {
    final today = DateTime(now.year, now.month, now.day);
    for (final day in daily) {
      if (day.date == today) return day;
    }
    return daily.isEmpty ? null : daily.first;
  }

  List<HourConditions> hoursOn(DateTime date) => hourly
      .where((hour) =>
          hour.time.year == date.year &&
          hour.time.month == date.month &&
          hour.time.day == date.day)
      .toList();

  /// Mean temperature across the whole forecast, used as a local stand-in for
  /// "normal" so a cold snap can be detected without a climatology table.
  double get meanTemperature {
    if (hourly.isEmpty) return current.temperature;
    final total =
        hourly.fold<double>(0, (sum, hour) => sum + hour.temperature);
    return total / hourly.length;
  }
}

/// Shared so the 15-minute cache survives closing and reopening the card.
final WeatherService defaultWeatherService = WeatherService();

class WeatherService {
  WeatherService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  final Map<String, _CacheEntry> _cache = {};

  /// Open-Meteo's free tier allows 10k calls a day. Coordinates are bucketed to
  /// ~1 km and held for 15 minutes so panning around one area does not spend
  /// that budget, and the pin does not need to be exact for weather.
  static const _ttl = Duration(minutes: 15);

  Future<WeatherReport> fetch(double latitude, double longitude) async {
    final key = '${latitude.toStringAsFixed(2)},${longitude.toStringAsFixed(2)}';
    final cached = _cache[key];
    if (cached != null && DateTime.now().difference(cached.at) < _ttl) {
      return cached.report;
    }

    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': latitude.toStringAsFixed(4),
      'longitude': longitude.toStringAsFixed(4),
      'current': 'temperature_2m,relative_humidity_2m,precipitation,'
          'weather_code,cloud_cover,pressure_msl,wind_speed_10m,'
          'wind_direction_10m,wind_gusts_10m',
      'hourly': 'temperature_2m,precipitation_probability,precipitation,'
          'weather_code,cloud_cover,pressure_msl,wind_speed_10m,'
          'wind_direction_10m,wind_gusts_10m',
      'daily': 'weather_code,temperature_2m_max,temperature_2m_min,'
          'precipitation_sum,precipitation_probability_max,'
          'wind_speed_10m_max,wind_direction_10m_dominant,sunrise,sunset',
      'timezone': 'auto',
      'forecast_days': '7',
      'wind_speed_unit': 'kmh',
      'temperature_unit': 'celsius',
    });

    final http.Response response;
    try {
      response = await _client
          .get(uri, headers: {'User-Agent': 'OpenWoodsMap/0.1'})
          .timeout(const Duration(seconds: 20));
    } catch (error) {
      throw const WeatherUnavailable(
        'Could not reach the weather service. Weather needs a connection; '
        'everything else in this card works offline.',
      );
    }
    if (response.statusCode != 200) {
      throw WeatherUnavailable(
        'Weather service returned ${response.statusCode}.',
      );
    }

    final report = parseWeather(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
    _cache[key] = _CacheEntry(report, DateTime.now());
    return report;
  }

  void dispose() => _client.close();
}

class _CacheEntry {
  const _CacheEntry(this.report, this.at);
  final WeatherReport report;
  final DateTime at;
}

double _double(Object? value) =>
    value is num ? value.toDouble() : double.tryParse('$value') ?? 0;

int _int(Object? value) =>
    value is num ? value.round() : int.tryParse('$value') ?? 0;

/// Split out from the fetch so the parsing is testable without a network call.
WeatherReport parseWeather(Map<String, dynamic> json) {
  final current = json['current'] as Map<String, dynamic>?;
  final hourly = json['hourly'] as Map<String, dynamic>?;
  final daily = json['daily'] as Map<String, dynamic>?;
  if (current == null || hourly == null || daily == null) {
    throw const WeatherUnavailable('Weather response was incomplete.');
  }

  final times = (hourly['time'] as List<dynamic>? ?? const []);
  final hours = <HourConditions>[];
  for (var i = 0; i < times.length; i++) {
    double at(String field) {
      final list = hourly[field] as List<dynamic>?;
      return list == null || i >= list.length ? 0 : _double(list[i]);
    }

    int atInt(String field) {
      final list = hourly[field] as List<dynamic>?;
      return list == null || i >= list.length ? 0 : _int(list[i]);
    }

    hours.add(
      HourConditions(
        time: DateTime.parse(times[i] as String),
        temperature: at('temperature_2m'),
        windSpeed: at('wind_speed_10m'),
        windDirection: atInt('wind_direction_10m'),
        windGusts: at('wind_gusts_10m'),
        pressure: at('pressure_msl'),
        precipitation: at('precipitation'),
        precipitationChance: atInt('precipitation_probability'),
        cloudCover: atInt('cloud_cover'),
        weatherCode: atInt('weather_code'),
      ),
    );
  }

  final dayTimes = (daily['time'] as List<dynamic>? ?? const []);
  final days = <DayForecast>[];
  for (var i = 0; i < dayTimes.length; i++) {
    double at(String field) {
      final list = daily[field] as List<dynamic>?;
      return list == null || i >= list.length ? 0 : _double(list[i]);
    }

    int atInt(String field) {
      final list = daily[field] as List<dynamic>?;
      return list == null || i >= list.length ? 0 : _int(list[i]);
    }

    DateTime atTime(String field, DateTime fallback) {
      final list = daily[field] as List<dynamic>?;
      if (list == null || i >= list.length) return fallback;
      return DateTime.tryParse('${list[i]}') ?? fallback;
    }

    final date = DateTime.parse(dayTimes[i] as String);
    days.add(
      DayForecast(
        date: DateTime(date.year, date.month, date.day),
        high: at('temperature_2m_max'),
        low: at('temperature_2m_min'),
        precipitationSum: at('precipitation_sum'),
        precipitationChance: atInt('precipitation_probability_max'),
        maxWind: at('wind_speed_10m_max'),
        dominantWindDirection: atInt('wind_direction_10m_dominant'),
        weatherCode: atInt('weather_code'),
        sunrise: atTime('sunrise', date.add(const Duration(hours: 6))),
        sunset: atTime('sunset', date.add(const Duration(hours: 18))),
      ),
    );
  }

  return WeatherReport(
    latitude: _double(json['latitude']),
    longitude: _double(json['longitude']),
    utcOffset: Duration(seconds: _int(json['utc_offset_seconds'])),
    current: HourConditions(
      time: DateTime.parse(current['time'] as String),
      temperature: _double(current['temperature_2m']),
      windSpeed: _double(current['wind_speed_10m']),
      windDirection: _int(current['wind_direction_10m']),
      windGusts: _double(current['wind_gusts_10m']),
      pressure: _double(current['pressure_msl']),
      precipitation: _double(current['precipitation']),
      precipitationChance: 0,
      cloudCover: _int(current['cloud_cover']),
      weatherCode: _int(current['weather_code']),
    ),
    hourly: hours,
    daily: days,
    fetchedAt: DateTime.now(),
  );
}

/// WMO weather codes, as returned in `weather_code`.
String weatherDescription(int code) => switch (code) {
      0 => 'Clear',
      1 => 'Mainly clear',
      2 => 'Partly cloudy',
      3 => 'Overcast',
      45 || 48 => 'Fog',
      51 => 'Light drizzle',
      53 => 'Drizzle',
      55 => 'Heavy drizzle',
      56 || 57 => 'Freezing drizzle',
      61 => 'Light rain',
      63 => 'Rain',
      65 => 'Heavy rain',
      66 || 67 => 'Freezing rain',
      71 => 'Light snow',
      73 => 'Snow',
      75 => 'Heavy snow',
      77 => 'Snow grains',
      80 => 'Light showers',
      81 => 'Showers',
      82 => 'Violent showers',
      85 || 86 => 'Snow showers',
      95 => 'Thunderstorm',
      96 || 99 => 'Thunderstorm with hail',
      _ => 'Unknown',
    };

/// Compass point for a bearing the wind is coming *from*.
String windCompass(int degrees) {
  const points = [
    'N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE',
    'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW',
  ];
  final index = (((degrees % 360) / 22.5).round()) % 16;
  return points[index];
}
