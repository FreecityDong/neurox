/// The tested Windows SDK numerical reconstruction, with independent attempt state.
const baselineAlgorithmVersion = 'neurox-sdk-learning-reference-v4';
const referenceMetricKeys = ['attention', 'relax'];
const minimumReferenceVariance = 0.0;
const baselineAdaptationSeconds = 10;
const baselineMinimumSeconds = 90;
const baselineMaximumSeconds = 180;
const baselineUsageVersion = 'personal-reference-v1';
const baselineReadingVersion = 'neutral-reading-v1';

Map<String, dynamic> baselineFeatureDefinition() => {
  'version': baselineAlgorithmVersion,
  'source':
      'Windows v2.1 eeg_lib.dll numerical reconstruction / RecoveredEegAlgorithms',
  'attention': '60*s, s=0.3*(beta/theta)+0.7*previous_s',
  'relax': '20*s, s=0.3*((alpha+theta)/beta)+0.7*previous_s',
  'saturation': 'v>99 => rand()%12+85; original SDK rule retained',
  'spectrum':
      'SDK 1024 samples, 256-sample hop, fixed 512Hz; original band sums and dual-channel power mean',
  'preprocessing': 'same recovered SDK 1-48 filter as diagnostic pipeline',
  'scoreUpdate':
      'each 256 new samples; each score queried once; UI reads cached values only',
  'windowSeconds': 4,
  'hopSeconds': 1,
  'warmupSeconds': 6,
  'baselineSampling':
      'last unique SDK update in each completed host-monotonic second; median of 5 consecutive valid seconds',
  'referenceStatistics':
      'one completed valid comparison second, one weight; mean and population variance',
  'minimumReferenceVariance': minimumReferenceVariance,
  'sdkSourceVersion':
      'Windows F-version v2.1.0 / unchanged reconstructed scores',
  'adaptationSeconds': baselineAdaptationSeconds,
  'minimumStatisticsSeconds': baselineMinimumSeconds,
  'maximumStatisticsSeconds': baselineMaximumSeconds,
  'minimumValidSeconds': 60,
  'minimumCoverage': .7,
  'maximumStandardDeviation': 20,
  'maximumDrift': 10,
  'usageVersion': baselineUsageVersion,
  'referenceLifetime':
      'persisted per account; explicit rerecord; compatible device and algorithm configuration',
  'readingVersion': baselineReadingVersion,
  'interpretation':
      'official SDK reconstructed scores; independent personal reference, not a firmware-equivalence claim',
};

bool validReferenceFeatures(Map<String, double>? features) =>
    features != null &&
    features.isNotEmpty &&
    features.values.every((v) => v.isFinite) &&
    referenceMetricKeys.every(
      (key) =>
          features[key] != null && features[key]! >= 0 && features[key]! <= 100,
    );
