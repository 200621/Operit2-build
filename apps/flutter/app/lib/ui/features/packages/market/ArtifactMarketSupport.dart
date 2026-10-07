// ignore_for_file: file_names

import '../../../../core/proxy/generated/CoreProxyClients.g.dart';
import '../../../../core/proxy/generated/CoreProxyModels.g.dart';

/// Minimum client version recorded for every marketplace publication.
const String marketMinimumAppVersion = '2.0.0';

/// Maximum client version recorded for every marketplace publication.
const String marketMaximumAppVersion = '2.99.99';
final Uri coreMarketAuthCompletionRedirectUri = Uri.parse(
  'https://api.operit.app/oauth/github/complete',
);

String firstNonBlank(Iterable<String> values) {
  for (final value in values) {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) {
      return trimmed;
    }
  }
  return '';
}

String artifactTypeLabel(String type) {
  return switch (type.trim()) {
    'package' => 'Package',
    'script' => 'Script',
    final value when value.isNotEmpty => value,
    _ => 'Artifact',
  };
}

/// Starts a broker transaction for one Flutter market browser surface.
Future<GitHubOAuthBrokerLoginStart> startCoreMarketAuthLogin({
  required GeneratedCoreProxyClients clients,
  Uri? completionRedirectUri,
}) async {
  final redirectUri =
      completionRedirectUri ?? coreMarketAuthCompletionRedirectUri;
  final broker = clients.servicesGitHubOAuthBrokerService;
  final start = await broker.startLogin(
    completionRedirectUri: redirectUri.toString(),
  );
  final authorizationUrl = Uri.tryParse(start.authorizationUrl);
  if (authorizationUrl == null ||
      authorizationUrl.scheme != 'https' ||
      authorizationUrl.host != 'github.com') {
    throw StateError('Invalid GitHub OAuth authorizationUrl');
  }
  return start;
}

/// Claims the GitHub OAuth broker transaction after the browser reaches its completion URL.
Future<String> completeCoreMarketAuthLogin({
  required GeneratedCoreProxyClients clients,
  required GitHubOAuthBrokerLoginStart start,
  required Uri completionUrl,
  Uri? completionRedirectUri,
}) async {
  final redirectUri =
      completionRedirectUri ?? coreMarketAuthCompletionRedirectUri;
  if (!isMarketAuthCompletionUri(completionUrl, redirectUri: redirectUri)) {
    throw StateError('GitHub OAuth callback destination is invalid');
  }
  final broker = clients.servicesGitHubOAuthBrokerService;
  final result = await broker.completeLogin(
    completion: GitHubOAuthBrokerLoginCompletion(
      attemptId: start.attemptId,
      completionUrl: completionUrl.toString(),
    ),
  );
  return result.login;
}

/// Returns whether one browser navigation reached the default OAuth completion destination.
bool isCoreMarketAuthCompletionUri(Uri uri) {
  return isMarketAuthCompletionUri(
    uri,
    redirectUri: coreMarketAuthCompletionRedirectUri,
  );
}

/// Returns whether a browser URL reached the callback destination for one login.
bool isMarketAuthCompletionUri(Uri uri, {required Uri redirectUri}) {
  return uri.scheme == redirectUri.scheme &&
      uri.host == redirectUri.host &&
      uri.port == redirectUri.port &&
      uri.path == redirectUri.path;
}

String formatMarketDate(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return '-';
  }
  return trimmed.length >= 10 ? trimmed.substring(0, 10) : trimmed;
}
