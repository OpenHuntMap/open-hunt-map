/// A transparent movement heuristic for white-tailed deer.
///
/// This is a rule of thumb, not a prediction, and the UI says so. Every hour's
/// score comes with the list of reasons that produced it, so the user can judge
/// the reasoning instead of trusting a number. Nothing here is fitted to
/// observed harvest data — we have none — and the weights below are editorial.
///
/// What the factors rest on, honestly graded:
///   * Crepuscular timing (dawn/dusk peaks) — well established, so it sets the
///     base score rather than acting as a modifier.
///   * Rut timing — well established. Ontario's peak is roughly Nov 5-25, and
///     its effect is mostly to add daytime movement, so the bonus is weighted
///     toward midday.
///   * Temperature below local normal — good support. "Normal" is the mean of
///     the returned forecast, which needs no climatology table and adapts to
///     wherever and whenever the user is.
///   * Strong wind suppressing movement — moderate support.
///   * Heavy precipitation suppressing movement — moderate support.
///   * Pressure change around a front — weak and contested, so it carries the
///     smallest weights.
///
/// Moon phase is deliberately excluded. It is the most popular factor in
/// hunting folklore and the telemetry studies that have looked for it largely
/// fail to find an effect on daily activity timing. Adding it would make the
/// output look more authoritative without making it more accurate.
library;

import 'dart:math' as math;

import 'weather.dart';

/// One reason an hour scored the way it did.
class ActivityFactor {
  const ActivityFactor(this.label, this.delta);
  final String label;
  final int delta;
}

class HourRating {
  const HourRating({
    required this.time,
    required this.score,
    required this.factors,
    required this.legalLight,
  });

  final DateTime time;

  /// 0-100. Comparable between hours at one place, not between places.
  final int score;
  final List<ActivityFactor> factors;

  /// Whether this hour falls in legal light for big game.
  final bool legalLight;

  ActivityBand get band => switch (score) {
        >= 70 => ActivityBand.high,
        >= 50 => ActivityBand.moderate,
        >= 30 => ActivityBand.low,
        _ => ActivityBand.veryLow,
      };
}

enum ActivityBand {
  veryLow('Very low'),
  low('Low'),
  moderate('Moderate'),
  high('High');

  const ActivityBand(this.label);
  final String label;
}

/// A run of consecutive legal hours worth sitting.
class ActivityWindow {
  const ActivityWindow({
    required this.start,
    required this.end,
    required this.peakScore,
    required this.reasons,
  });

  final DateTime start;
  final DateTime end;
  final int peakScore;
  final List<String> reasons;
}

class DeerActivity {
  const DeerActivity({required this.hours, required this.windows});

  final List<HourRating> hours;
  final List<ActivityWindow> windows;

  HourRating? ratingAt(DateTime time) {
    for (final hour in hours) {
      if (hour.time.hour == time.hour &&
          hour.time.day == time.day &&
          hour.time.month == time.month) {
        return hour;
      }
    }
    return null;
  }

  /// Scores every hour of [day] and groups the good legal ones into windows.
  static DeerActivity forDay(WeatherReport report, DayForecast day) {
    final hours = report.hoursOn(day.date);
    final normal = report.meanTemperature;
    final rated = <HourRating>[];

    for (final hour in hours) {
      final factors = <ActivityFactor>[];

      // Base: distance from the nearest edge of the day.
      final fromSunrise =
          hour.time.difference(day.sunrise).inMinutes.abs();
      final fromSunset = hour.time.difference(day.sunset).inMinutes.abs();
      final edge = math.min(fromSunrise, fromSunset);
      final legal = !hour.time.isBefore(day.legalStart) &&
          !hour.time.isAfter(day.legalEnd);
      final isNight =
          hour.time.isBefore(day.sunrise) || hour.time.isAfter(day.sunset);

      int score;
      if (edge <= 60) {
        score = 70;
        factors.add(
          ActivityFactor(
            fromSunrise <= fromSunset ? 'First light' : 'Last light',
            70,
          ),
        );
      } else if (edge <= 120) {
        score = 55;
        factors.add(const ActivityFactor('Near dawn/dusk', 55));
      } else if (isNight) {
        score = 45;
        factors.add(const ActivityFactor('Night movement', 45));
      } else {
        score = 30;
        factors.add(const ActivityFactor('Midday lull', 30));
      }

      // Rut: the one factor that reliably puts deer on their feet at noon.
      final rut = _rutBonus(hour.time);
      if (rut > 0) {
        final bonus = isNight || edge <= 60 ? (rut / 2).round() : rut;
        score += bonus;
        factors.add(ActivityFactor(_rutLabel(hour.time), bonus));
      }

      // Temperature against the local forecast mean.
      final belowNormal = normal - hour.temperature;
      if (belowNormal >= 6) {
        score += 12;
        factors.add(const ActivityFactor('Well below normal temp', 12));
      } else if (belowNormal >= 3) {
        score += 7;
        factors.add(const ActivityFactor('Cooler than normal', 7));
      } else if (belowNormal <= -6) {
        score -= 6;
        factors.add(const ActivityFactor('Unseasonably warm', -6));
      }

      // Wind.
      if (hour.windSpeed >= 35) {
        score -= 20;
        factors.add(const ActivityFactor('Very strong wind', -20));
      } else if (hour.windSpeed >= 25) {
        score -= 12;
        factors.add(const ActivityFactor('Strong wind', -12));
      } else if (hour.windSpeed >= 6 && hour.windSpeed <= 16) {
        score += 5;
        factors.add(const ActivityFactor('Steady usable wind', 5));
      } else if (hour.windSpeed <= 2) {
        score -= 3;
        factors.add(const ActivityFactor('Dead calm carries scent', -3));
      }
      if (hour.windGusts >= 45) {
        score -= 8;
        factors.add(const ActivityFactor('Hard gusts', -8));
      }

      // Precipitation.
      if (hour.weatherCode >= 95) {
        score -= 20;
        factors.add(const ActivityFactor('Thunderstorm', -20));
      } else if (hour.precipitation >= 4) {
        score -= 15;
        factors.add(const ActivityFactor('Heavy precipitation', -15));
      } else if (hour.precipitation >= 1) {
        score -= 5;
        factors.add(const ActivityFactor('Steady precipitation', -5));
      } else if (hour.precipitation >= 0.1) {
        score += 3;
        factors.add(const ActivityFactor('Light drizzle quiets the bush', 3));
      }

      // Pressure, weighted lightly on purpose.
      final trend = _pressureTrend(report, hour);
      if (trend != null) {
        if (trend >= 2) {
          score += 8;
          factors.add(const ActivityFactor('Pressure rising behind a front', 8));
        } else if (trend <= -2) {
          score += 6;
          factors.add(const ActivityFactor('Pressure falling ahead of a front', 6));
        } else if (hour.pressure >= 1020) {
          score += 3;
          factors.add(const ActivityFactor('Settled high pressure', 3));
        }
      }

      rated.add(
        HourRating(
          time: hour.time,
          score: score.clamp(0, 100),
          factors: factors,
          legalLight: legal,
        ),
      );
    }

    return DeerActivity(hours: rated, windows: _windows(rated));
  }

  /// Ontario's rut runs through November, peaking in the middle. Dates are
  /// approximate and shift with latitude.
  static int _rutBonus(DateTime time) {
    if (time.month == 11) {
      if (time.day >= 5 && time.day <= 25) return 18;
      return 10;
    }
    // Pre-rut scraping and post-rut seeking taper either side.
    if (time.month == 10 && time.day >= 20) return 8;
    if (time.month == 12 && time.day <= 10) return 8;
    return 0;
  }

  static String _rutLabel(DateTime time) {
    if (time.month == 11 && time.day >= 5 && time.day <= 25) return 'Peak rut';
    if (time.month == 10) return 'Pre-rut';
    if (time.month == 12) return 'Post-rut';
    return 'Rut';
  }

  /// Change in hPa over the three hours before [hour], or null if the forecast
  /// does not reach back that far.
  static double? _pressureTrend(WeatherReport report, HourConditions hour) {
    final earlier = hour.time.subtract(const Duration(hours: 3));
    for (final candidate in report.hourly) {
      if (candidate.time == earlier) {
        return hour.pressure - candidate.pressure;
      }
    }
    return null;
  }

  /// Groups legal hours that score within 10 of the day's legal peak.
  static List<ActivityWindow> _windows(List<HourRating> rated) {
    final legal = rated.where((hour) => hour.legalLight).toList();
    if (legal.isEmpty) return const [];
    final peak = legal.map((hour) => hour.score).reduce(math.max);
    final threshold = math.max(peak - 10, 45);

    final windows = <ActivityWindow>[];
    List<HourRating> run = [];

    void flush() {
      if (run.isEmpty) return;
      final best = run.reduce((a, b) => b.score > a.score ? b : a);
      windows.add(
        ActivityWindow(
          start: run.first.time,
          end: run.last.time.add(const Duration(hours: 1)),
          peakScore: best.score,
          reasons: best.factors
              .where((factor) => factor.delta > 0)
              .map((factor) => factor.label)
              .toList(),
        ),
      );
      run = [];
    }

    for (final hour in legal) {
      if (hour.score >= threshold) {
        if (run.isNotEmpty &&
            hour.time.difference(run.last.time) > const Duration(hours: 1)) {
          flush();
        }
        run.add(hour);
      } else {
        flush();
      }
    }
    flush();

    windows.sort((a, b) => b.peakScore.compareTo(a.peakScore));
    return windows;
  }
}
