/// Conference/video entry point of a meeting.
///
/// Immutable: all fields are final and the class is a pure value type with
/// structural equality.
class MeetingJoinInfo {
  const MeetingJoinInfo({required this.url, this.provider});

  /// The URL the user opens to join the meeting.
  final String url;

  /// Optional informational provider label, e.g. `google_meet`, `zoom`,
  /// `teams`. Never used for scheduling decisions.
  final String? provider;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MeetingJoinInfo && other.url == url && other.provider == provider;

  @override
  int get hashCode => Object.hash(url, provider);

  @override
  String toString() => 'MeetingJoinInfo(url: $url, provider: $provider)';
}
