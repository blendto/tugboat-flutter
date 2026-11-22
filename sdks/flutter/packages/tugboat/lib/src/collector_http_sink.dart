import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'capture_sink.dart';
import 'collector_config.dart';
import 'collector_mapper.dart';
import 'models.dart';
import 'sdk_version.dart';

const _httpProofEnabled =
    kDebugMode && bool.fromEnvironment('TUGBOAT_HTTP_PROOF');

const _collectorHttpProofPaths = {
  '/v1/sessions',
  '/v1/events/batch',
  '/v1/frames',
};

final _safeHttpProofId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

/// Redacted Device Farm HTTP proof line. Never includes origins, queries,
/// payloads, or API keys.
@visibleForTesting
String formatCollectorHttpProofLine({
  required String path,
  String? localSessionId,
  String? returnedSessionId,
  int? statusCode,
  required int durationMs,
  Object? error,
}) {
  final safePath = _collectorHttpProofPaths.contains(path) ? path : 'redacted';
  final line =
      'TUGBOAT_HTTP method=POST path=$safePath '
      'localSessionId=${_safeHttpProofIdValue(localSessionId)} '
      'returnedSessionId=${_safeHttpProofIdValue(returnedSessionId)} '
      'status=${statusCode ?? 'null'} '
      'durationMs=$durationMs';
  if (error == null) return line;
  return '$line exception=${error.runtimeType}';
}

String _safeHttpProofIdValue(String? value) => value == null
    ? 'null'
    : _safeHttpProofId.hasMatch(value)
    ? value
    : 'redacted';

/// Best-effort HTTP sink for the standalone `tugboat-collector` service.
class CollectorHttpSink implements TugboatCaptureSink, TugboatSinkBacklog {
  CollectorHttpSink({
    required TugboatCollectorConfig config,
    http.Client? client,
    Map<String, dynamic>? initialTraits,
    String? initialTraitsId,
    String? initialUserId,
    @visibleForTesting Duration? identityDebounceDuration,
    @visibleForTesting Duration? requestTimeout,
    @visibleForTesting Duration? slowFlushThreshold,
    @visibleForTesting DateTime Function()? wallClock,
    @visibleForTesting Stopwatch Function()? stopwatchFactory,
  }) : _config = config,
       _wallClock = wallClock ?? DateTime.now,
       _stopwatchFactory = stopwatchFactory ?? Stopwatch.new,
       _requestTimeout = requestTimeout ?? _defaultRequestTimeout,
       _slowFlushThreshold = slowFlushThreshold ?? _defaultSlowFlushThreshold,
       _userId = initialUserId ?? config.userId,
       _traits = initialTraits == null
           ? null
           : Map<String, dynamic>.from(initialTraits),
       _traitsId = initialTraitsId,
       _identityDebounceDuration =
           identityDebounceDuration ?? _defaultIdentityDebounceDuration,
       _client = _CollectorHttpClient(
         inner: client ?? http.Client(),
         apiKey: config.apiKey,
         platform: config.deviceInfo.platform,
         buildNumber: config.appInfo.buildNumber,
         versionName: config.appInfo.version,
         appId: config.appInfo.appId,
       );

  final TugboatCollectorConfig _config;
  final _CollectorHttpClient _client;

  /// Upper bound for one collector request. package:http has no default
  /// timeout, and a single stuck socket would otherwise hold the
  /// single-flight flush (and every later upload) for minutes.
  static const _defaultRequestTimeout = Duration(seconds: 15);
  final Duration _requestTimeout;

  /// A flush pass slower than this records a `collector_flush` diagnostic.
  static const _defaultSlowFlushThreshold = Duration(seconds: 10);
  final Duration _slowFlushThreshold;

  /// Wall clock, for absolute timestamps only (`triggeredAt`).
  final DateTime Function() _wallClock;
  final Stopwatch Function() _stopwatchFactory;

  /// Started with the session. Every duration since the session start
  /// (`atMs`) is read from it, so a wall-clock change (NTP, the user setting
  /// the clock) cannot make a lifecycle post or diagnostic go backwards.
  Stopwatch? _sessionStopwatch;

  /// Time between the session's `startedAt` and [startSession], added to
  /// [_sessionStopwatch]. The controller starts its event clock and stamps
  /// `startedAt` before notifying listeners and building factory sinks, so a
  /// stopwatch started here alone would run behind every event `atMs`, and
  /// `session_end` could land before the session's last event. Read once
  /// from the wall clock at session start; only the stopwatch advances it.
  Duration _sessionStartOffset = Duration.zero;

  bool _disposed = false;
  TugboatSession? _session;

  /// Collector-issued id; null until session_start is accepted.
  String? _collectorSessionId;
  int _sessionEpoch = 0;
  Timer? _flushTimer;
  Future<void>? _flushInFlight;
  Future<void>? _followUpFlush;
  bool _framesNeedRetry = false;
  bool _frameUploadFailureReported = false;
  int _diagnosticSequence = 0;
  int _droppedFrameCount = 0;
  int _droppedReferencedFrameCount = 0;
  int _reportedDroppedFrameCount = 0;
  int _nextDropReportAt = 1;

  /// Frame numbers that a recorded event points at (`beforeFrame` /
  /// `afterFrame`). Eviction keeps these over unreferenced captures.
  final Set<int> _referencedFrameNos = {};

  /// Recently uploaded or evicted frame numbers, so an event that arrives
  /// after its frame left the queue does not mark it again. Bounded by
  /// `maxPendingFrames`.
  final LinkedHashSet<int> _finishedFrameNos = LinkedHashSet<int>();

  /// Session and event paths whose current outage was already reported.
  final Set<String> _failingRequestPaths = {};

  /// Whether this outage already reported a slow flush. A pass that waits out
  /// one timeout is slow, so without this every pass of a hang would queue a
  /// diagnostic, and those would push real events out of the retry queue.
  bool _slowFlushReported = false;

  /// Whether the last event post got no response (timeout or transport
  /// error), as opposed to a status code.
  bool _lastEventPostUnanswered = false;
  final List<Map<String, Object?>> _pendingEvents = [];
  final List<_PendingFrameUpload> _pendingFrames = [];
  final List<List<Map<String, Object?>>> _retryBatches = [];
  final List<_PendingSessionLifecycle> _pendingLifecycle = [];

  /// Events and frames taken out of their queues for a request that has not
  /// finished. They still count as pending: a stalled request would otherwise
  /// make the backlog read 0. A new session or [dispose] does not reset
  /// them: a request already sent may still be delivered, so its items stay
  /// pending until it settles, and only then count as dropped if the
  /// collector left them to retry (see [_settleStaleRequest]).
  int _inFlightEvents = 0;
  int _inFlightFrames = 0;

  /// Events and frames discarded for the lifetime of the sink: at the bounded
  /// caps, as backlog cleared by a new session or [dispose], and as requests
  /// from a replaced session that the collector left to retry. Unlike
  /// [_droppedFrameCount] this is not reset per session and does not drive
  /// any wire diagnostic.
  int _droppedTotal = 0;

  /// Runtime user id (may change via [setUserId]).
  String? _userId;

  /// Full traits bag last provided by the host (process-local).
  Map<String, dynamic>? _traits;

  /// Collector-issued traits dictionary id.
  String? _traitsId;

  /// How long to wait after the last identity change before posting.
  ///
  /// Boot flows often resolve userId and traits in separate calls (auth restore,
  /// billing, feature flags). Debouncing merges those into one lifecycle POST
  /// (`session_identify` when both change) instead of back-to-back
  /// `user_changed` / `traits_updated`.
  static const _defaultIdentityDebounceDuration = Duration(seconds: 3);

  final Duration _identityDebounceDuration;

  Timer? _identityDebounceTimer;
  bool _userDirty = false;
  bool _traitsDirty = false;
  _Trigger? _userTrigger;
  _Trigger? _traitsTrigger;

  Uri get _baseUri => Uri.parse(_config.baseUrl.replaceAll(RegExp(r'/+$'), ''));

  bool get _hasCollectorSessionId =>
      _collectorSessionId != null && _collectorSessionId!.isNotEmpty;

  /// Last collector-issued traits id, if any.
  String? get traitsId => _traitsId;

  /// Last host-provided traits bag, if any.
  Map<String, dynamic>? get traits =>
      _traits == null ? null : Map<String, dynamic>.unmodifiable(_traits!);

  /// Current runtime user id stamped on sessions and events.
  String? get userId => _userId;

  /// Events and frames waiting for delivery, including those in a request.
  @override
  int get pendingCount =>
      _pendingEvents.length +
      _retryEventCount +
      _inFlightEvents +
      _pendingFrames.length +
      _inFlightFrames;

  /// Events and frames discarded at the bounds, or cleared undelivered by a
  /// new session or [dispose].
  @override
  int get droppedCount => _droppedTotal;

  int get _retryEventCount =>
      _retryBatches.fold<int>(0, (sum, batch) => sum + batch.length);

  @override
  void startSession(TugboatSession session) {
    if (_disposed) return;
    _sessionEpoch += 1;
    _session = session;
    // Clear any prior collector-issued id so a new session cannot route to the old one.
    // Traits / traitsId persist across sessions for the process lifetime.
    _collectorSessionId = null;
    _discardBacklog();
    _pendingLifecycle.clear();
    _sessionStopwatch = _stopwatchFactory()..start();
    _sessionStartOffset = _startOffset(session);
    _framesNeedRetry = false;
    _frameUploadFailureReported = false;
    _diagnosticSequence = 0;
    _resetDropTracking();
    _cancelIdentityDebounce();
    _userDirty = false;
    _traitsDirty = false;
    _userTrigger = null;
    _traitsTrigger = null;
    _scheduleFlushTimer();
    _enqueueSessionLifecycle(
      TugboatCollectorSessionEventType.sessionStart.wireValue,
      (at: session.startedAt, elapsed: Duration.zero),
    );
    unawaited(flush());
  }

  /// Counts the queued events and frames as dropped and clears them. Items
  /// in a request are not touched: that request may still deliver them.
  void _discardBacklog() {
    _droppedTotal +=
        _pendingEvents.length + _retryEventCount + _pendingFrames.length;
    _pendingEvents.clear();
    _pendingFrames.clear();
    _retryBatches.clear();
  }

  /// How long ago [session] started on the wall clock, never negative.
  Duration _startOffset(TugboatSession session) {
    final offset = _wallClock().difference(session.startedAt);
    return offset.isNegative ? Duration.zero : offset;
  }

  @override
  void recordEvent(TugboatEvent event) {
    if (_disposed || _session == null) return;
    if (event.type == 'session_start' || event.type == 'session_end') {
      // Lifecycle is sent through POST /v1/sessions.
      return;
    }

    _markReferencedFrame(event.beforeFrame);
    _markReferencedFrame(event.afterFrame);
    final session = _session!;
    // sessionId / traitsId are stamped at send time once known.
    _pendingEvents.add(
      mapTugboatEventToCollectorEvent(
        event: event,
        sessionStartedAt: session.startedAt,
        collectorConfig: _config,
        userId: _userId,
      ),
    );
    _trimPendingEvents();

    if (_pendingEvents.length >= _config.eventBatchSize) {
      unawaited(flush());
    }
  }

  void _markReferencedFrame(String? frameId) {
    if (frameId == null) return;
    final frameNo = frameNumberFromId(frameId);
    if (frameNo == null || _finishedFrameNos.contains(frameNo)) return;
    _referencedFrameNos.add(frameNo);
  }

  void _resetDropTracking() {
    _droppedFrameCount = 0;
    _droppedReferencedFrameCount = 0;
    _reportedDroppedFrameCount = 0;
    _nextDropReportAt = 1;
    _referencedFrameNos.clear();
    _finishedFrameNos.clear();
    _failingRequestPaths.clear();
    _lastEventPostUnanswered = false;
    _slowFlushReported = false;
  }

  @override
  void recordFrame(
    TugboatFrame frame,
    Uint8List bytes, {
    required String sessionId,
    String? actionId,
  }) {
    if (_disposed) return;
    // Enforce in release builds too — assert-only would let stale frames
    // upload under the wrong collector session after a rapid restart.
    final activeSession = _session;
    if (activeSession != null && activeSession.id != sessionId) {
      debugPrint(
        '[tugboat] collector dropped frame for stale sessionId: $sessionId '
        '(active=${activeSession.id})',
      );
      return;
    }
    final frameNo = frameNumberFromId(frame.id);
    if (frameNo == null) {
      debugPrint(
        '[tugboat] collector dropped frame with malformed id: ${frame.id}',
      );
      return;
    }
    _pendingFrames.add(
      _PendingFrameUpload(
        frameNo: frameNo,
        bytes: bytes,
        metadata: frame.toJson(),
      ),
    );
    _trimPendingFrames();
    // While a frame upload is retrying, rely on the periodic flush timer.
    if (!_framesNeedRetry) {
      unawaited(flush());
    }
  }

  @override
  Future<void> flush() {
    if (_disposed) return Future<void>.value();
    final active = _flushInFlight;
    if (active != null) {
      // The running pass has already taken its frame snapshot, so work queued
      // now may not be part of it. Run one more pass behind it; concurrent
      // callers share that pass and resolve only once their work had a turn.
      return _followUpFlush ??= _flushAfter(active);
    }

    late final Future<void> operation;
    operation = _flushOnce().whenComplete(() {
      if (identical(_flushInFlight, operation)) {
        _flushInFlight = null;
      }
    });
    _flushInFlight = operation;
    return operation;
  }

  /// Waits for [active], then runs another pass so newly enqueued work is sent.
  Future<void> _flushAfter(Future<void> active) async {
    try {
      await active;
    } on Object {
      // The running pass reports its own failure to its callers.
    }
    _followUpFlush = null;
    if (_disposed) return;
    await flush();
  }

  /// Registers a full traits snapshot with the collector.
  ///
  /// No-ops when [traits] equals the cached bag via [mapEquals] (shallow:
  /// nested maps/lists compared with `==`). While `session_start` is still
  /// pending, updates memory only (folded into start at send time). Otherwise
  /// debounces `traits_updated` or `session_identify` when combined with a
  /// pending user change within [_identityDebounceDuration].
  Future<void> setTraits(Map<String, dynamic> traits) async {
    if (_disposed) return;
    if (mapEquals(_traits, traits)) return;
    _traits = Map<String, dynamic>.from(traits);
    if (_session == null) return;
    if (_isSessionStartPending()) return;
    _traitsDirty = true;
    _traitsTrigger = _markTrigger();
    _scheduleIdentityDebounce();
  }

  /// Updates the runtime user id and notifies the collector.
  ///
  /// No-ops when [userId] equals the current runtime id. While `session_start`
  /// is still pending, updates memory only (folded into start at send time).
  /// Otherwise debounces `user_changed` or `session_identify` when combined
  /// with a pending traits change within [_identityDebounceDuration].
  Future<void> setUserId(String? userId) async {
    if (_disposed) return;
    if (userId == _userId) return;
    _userId = userId;
    if (_session == null) return;
    if (_isSessionStartPending()) return;
    _userDirty = true;
    _userTrigger = _markTrigger();
    _scheduleIdentityDebounce();
  }

  bool _isSessionStartPending() => _pendingLifecycle.any(
    (p) =>
        p.eventType == TugboatCollectorSessionEventType.sessionStart.wireValue,
  );

  void _scheduleIdentityDebounce() {
    _identityDebounceTimer?.cancel();
    _identityDebounceTimer = Timer(_identityDebounceDuration, () {
      _identityDebounceTimer = null;
      if (_disposed) return;
      _enqueueCoalescedIdentityUpdate();
      unawaited(_drainLifecyclePosts());
    });
  }

  void _cancelIdentityDebounce() {
    _identityDebounceTimer?.cancel();
    _identityDebounceTimer = null;
  }

  /// Flushes any debounced identity update immediately (no-op when clean).
  Future<void> _flushIdentityDebounce() async {
    _cancelIdentityDebounce();
    if (!_userDirty && !_traitsDirty) return;
    _enqueueCoalescedIdentityUpdate();
    await _drainLifecyclePosts();
  }

  /// Now, as a wall-clock timestamp plus the monotonic time since the session
  /// started. Order triggers by [_Trigger.elapsed], never by [_Trigger.at].
  _Trigger _markTrigger() => (at: _wallClock(), elapsed: _sessionElapsed());

  /// Time since the session started, on the controller's time base.
  Duration _sessionElapsed() {
    final watch = _sessionStopwatch;
    if (watch == null) return Duration.zero;
    return _sessionStartOffset + watch.elapsed;
  }

  int _elapsedMs() => _sessionElapsed().inMilliseconds;

  _Trigger _coalescedIdentityTrigger() {
    if (_userDirty && _traitsDirty) return _latestIdentityTrigger();
    if (_userDirty) return _userTrigger ?? _markTrigger();
    return _traitsTrigger ?? _markTrigger();
  }

  _Trigger _latestIdentityTrigger() {
    final user = _userTrigger;
    final traits = _traitsTrigger;
    if (user != null && traits != null) {
      return user.elapsed > traits.elapsed ? user : traits;
    }
    return user ?? traits ?? _markTrigger();
  }

  void _enqueueCoalescedIdentityUpdate() {
    if (_disposed || _session == null) return;
    if (!_userDirty && !_traitsDirty) return;

    final eventType = _userDirty && _traitsDirty
        ? TugboatCollectorSessionEventType.sessionIdentify.wireValue
        : _userDirty
        ? TugboatCollectorSessionEventType.userChanged.wireValue
        : TugboatCollectorSessionEventType.traitsUpdated.wireValue;
    final trigger = _coalescedIdentityTrigger();

    _userDirty = false;
    _traitsDirty = false;
    _enqueueSessionLifecycle(eventType, trigger);
    _userTrigger = null;
    _traitsTrigger = null;
  }

  @override
  Future<void> endSession() async {
    if (_disposed || _session == null) return;
    // A new session can start while this one drains. From then on the queues
    // and the flush timer are the new session's, so stop touching them.
    final epoch = _sessionEpoch;
    await _flushIdentityDebounce();
    await flush();
    await _flushFinalDropCount(epoch);
    if (!_isCurrentEpoch(epoch)) return;
    _enqueueSessionLifecycle(
      TugboatCollectorSessionEventType.sessionEnd.wireValue,
      _markTrigger(),
    );
    await _drainLifecyclePosts();
    if (_isCurrentEpoch(epoch)) _cancelFlushTimer();
  }

  /// Drop diagnostics are sampled at powers of two; sends the final count so
  /// the session's true gap is visible.
  Future<void> _flushFinalDropCount(int epoch) async {
    if (!_isCurrentEpoch(epoch)) return;
    if (_droppedFrameCount <= _reportedDroppedFrameCount) return;
    _recordDropDiagnostic();
    await flush();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelFlushTimer();
    _cancelIdentityDebounce();
    _userDirty = false;
    _traitsDirty = false;
    _userTrigger = null;
    _traitsTrigger = null;
    _client.close();
    _discardBacklog();
    _pendingLifecycle.clear();
    _sessionStopwatch = null;
    _referencedFrameNos.clear();
    _finishedFrameNos.clear();
    _flushInFlight = null;
    _followUpFlush = null;
    _session = null;
    _collectorSessionId = null;
    _sessionEpoch += 1;
  }

  bool _isCurrentEpoch(int epoch) => !_disposed && epoch == _sessionEpoch;

  void _scheduleFlushTimer() {
    _cancelFlushTimer();
    _flushTimer = Timer.periodic(_config.eventFlushInterval, (_) {
      unawaited(flush());
    });
  }

  void _cancelFlushTimer() {
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  void _enqueueSessionLifecycle(String eventType, _Trigger trigger) {
    _pendingLifecycle.add(
      _PendingSessionLifecycle(
        eventType: eventType,
        triggeredAt: trigger.at,
        atMs: trigger.elapsed.inMilliseconds,
        activeLocale:
            eventType == TugboatCollectorSessionEventType.sessionStart.wireValue
            ? _session?.locale
            : null,
      ),
    );
  }

  Future<void> _drainLifecyclePosts() async {
    final epoch = _sessionEpoch;
    while (_isCurrentEpoch(epoch) && _pendingLifecycle.isNotEmpty) {
      final head = _pendingLifecycle.first;
      await flush();
      // Stop only when the head was not accepted (still retrying). Advancing
      // from session_start → session_end must continue draining.
      if (_pendingLifecycle.isNotEmpty &&
          identical(head, _pendingLifecycle.first)) {
        return;
      }
    }
  }

  Future<void> _flushLifecyclePosts() async {
    if (_pendingLifecycle.isEmpty || _disposed) return;
    final pending = _pendingLifecycle.first;
    final epoch = _sessionEpoch;

    final result = await _sendSessionLifecycle(
      pending.eventType,
      pending.triggeredAt,
      pending.atMs,
      pending.activeLocale,
      epoch,
    );
    if (!_isCurrentEpoch(epoch)) return;
    if (_lifecyclePostSettled(pending.eventType, result)) {
      _pendingLifecycle.removeAt(0);
    }
  }

  /// Whether a lifecycle post leaves the queue. A post the collector rejects
  /// (4xx) would be rejected again, and leaving it at the head would hold
  /// every later post, `session_end` included, for the rest of the session.
  /// `session_start` stays until accepted: events and frames are gated on
  /// the collector session id it returns.
  bool _lifecyclePostSettled(String eventType, _SendResult result) {
    if (result == _SendResult.accepted) return true;
    return result == _SendResult.drop && !_isSessionStart(eventType);
  }

  Future<_SendResult> _sendSessionLifecycle(
    String eventType,
    DateTime triggeredAt,
    int atMs,
    TugboatLocaleInfo? activeLocale,
    int epoch,
  ) async {
    if (!_isCurrentEpoch(epoch)) return _SendResult.drop;
    final session = _session;
    if (session == null) return _SendResult.accepted;

    final sessionId = _sessionIdForLifecycle(eventType, session.id);
    final traits = _traits;

    final body = mapTugboatSessionLifecycleToCollectorSession(
      eventType: eventType,
      sessionId: sessionId,
      sessionStartedAt: session.startedAt,
      triggeredAt: triggeredAt,
      atMs: atMs,
      config: _config,
      userId: _userId,
      traits: traits,
      traitsId: traits == null ? _traitsId : null,
      activeLocale: activeLocale,
    );

    try {
      final response = await _postJson('/v1/sessions', body);

      final result = _classifyResponse(response.statusCode);
      if (!_isCurrentEpoch(epoch)) return result;
      if (result == _SendResult.accepted) {
        _applyLifecycleResponse(eventType, response.body, session.id);
      }
      _noteRequestOutcome('/v1/sessions', result, response.statusCode);
      return result;
    } catch (error) {
      if (_isCurrentEpoch(epoch)) _noteRequestError('/v1/sessions', error);
      return _SendResult.retry;
    }
  }

  String _sessionIdForLifecycle(String eventType, String localSessionId) =>
      _isSessionStart(eventType)
      ? localSessionId
      : _collectorSessionId ?? localSessionId;

  bool _isSessionStart(String eventType) =>
      eventType == TugboatCollectorSessionEventType.sessionStart.wireValue;

  void _applyLifecycleResponse(
    String eventType,
    String responseBody,
    String localSessionId,
  ) {
    final raw = responseBody.trim();
    if (raw.isEmpty) {
      _useLocalSessionIdForStart(eventType, localSessionId);
      return;
    }
    try {
      _applyDecodedLifecycleResponse(
        eventType,
        jsonDecode(raw) as Map<String, dynamic>,
        localSessionId,
      );
    } on Object {
      _useLocalSessionIdForStart(eventType, localSessionId);
    }
  }

  void _applyDecodedLifecycleResponse(
    String eventType,
    Map<String, dynamic> decoded,
    String localSessionId,
  ) {
    if (_isSessionStart(eventType)) {
      final serverId = decoded['sessionId'] as String?;
      _collectorSessionId = serverId != null && serverId.isNotEmpty
          ? serverId
          : localSessionId;
    }
    final responseTraitsId = decoded['traitsId'] as String?;
    if (responseTraitsId != null && responseTraitsId.isNotEmpty) {
      _traitsId = responseTraitsId;
    }
  }

  void _useLocalSessionIdForStart(String eventType, String localSessionId) {
    if (_isSessionStart(eventType)) _collectorSessionId ??= localSessionId;
  }

  /// Sends the next event batch. Returns how many events it took and whether
  /// the collector left it to retry.
  Future<({int count, bool retry})> _flushEventBatch() async {
    if (_pendingEvents.isEmpty) return (count: 0, retry: false);
    final epoch = _sessionEpoch;

    final count = _pendingEvents.length < _config.eventBatchSize
        ? _pendingEvents.length
        : _config.eventBatchSize;
    final batch = _pendingEvents.sublist(0, count);
    _pendingEvents.removeRange(0, count);
    _inFlightEvents += count;

    final result = await _sendEventBatch(batch, epoch: epoch);
    _inFlightEvents -= count;
    if (!_isCurrentEpoch(epoch)) {
      _settleStaleRequest(result, count);
      return (count: count, retry: false);
    }
    if (result != _SendResult.retry) return (count: count, retry: false);
    _enqueueRetryBatch(batch);
    return (count: count, retry: true);
  }

  /// Moves the next [count] pending events into retry batches without
  /// sending them, batched exactly as the drain would have sent them (the
  /// last batch fills up with later events). They keep the same retention as
  /// batches that were sent and failed, and go out in order once the
  /// collector accepts the retry head. Events that arrived later stay pending
  /// for the next pass, so they cannot push this pass's batches out of the
  /// retry queue.
  void _parkPendingEvents(int count) {
    var left = count;
    while (left > 0 && _pendingEvents.isNotEmpty) {
      final batch = _retryBatchWithRoom();
      final room = _config.eventBatchSize - batch.length;
      final size = _pendingEvents.length < room ? _pendingEvents.length : room;
      batch.addAll(_pendingEvents.sublist(0, size));
      _pendingEvents.removeRange(0, size);
      left -= size;
    }
  }

  /// The newest retry batch when it has room, else a new one. Parking a few
  /// events per pass during an outage would otherwise fill the bounded retry
  /// queue with near-empty batches. Never the head: it is the batch that is
  /// failing, and events merged into it would fail, and be evicted, with it.
  List<Map<String, Object?>> _retryBatchWithRoom() {
    if (_retryBatches.length > 1 &&
        _retryBatches.last.length < _config.eventBatchSize) {
      return _retryBatches.last;
    }
    final batch = <Map<String, Object?>>[];
    _enqueueRetryBatch(batch);
    return batch;
  }

  /// Sends retry batches oldest first. The head leaves the retry queue while
  /// it is in a request, so a new session or [dispose] cannot count it as
  /// dropped while that request may still deliver it.
  Future<void> _flushRetryBatches() async {
    final epoch = _sessionEpoch;
    while (_retryBatches.isNotEmpty) {
      final head = _retryBatches.removeAt(0);
      _inFlightEvents += head.length;
      final result = await _sendEventBatch(head, epoch: epoch);
      _inFlightEvents -= head.length;
      if (!_isCurrentEpoch(epoch)) {
        _settleStaleRequest(result, head.length);
        return;
      }
      if (result == _SendResult.retry) {
        // Nothing else touches the retry queue during a pass (flushes are
        // single-flight), so putting the head back cannot exceed the cap.
        _retryBatches.insert(0, head);
        return;
      }
    }
  }

  /// Settles a request that finished after its session was replaced or the
  /// sink disposed. Its items are never requeued, so those the collector
  /// left to retry are lost; delivered and rejected ones are not (a rejected
  /// item is not counted as dropped in a live session either).
  void _settleStaleRequest(_SendResult result, int count) {
    if (result == _SendResult.retry) _droppedTotal += count;
  }

  void _enqueueRetryBatch(List<Map<String, Object?>> batch) {
    _retryBatches.add(batch);
    while (_retryBatches.length > _config.maxPendingBatches) {
      _droppedTotal += _retryBatches.removeAt(0).length;
    }
  }

  Future<_SendResult> _sendEventBatch(
    List<Map<String, Object?>> events, {
    required int epoch,
  }) async {
    if (events.isEmpty) return _SendResult.accepted;
    if (!_isCurrentEpoch(epoch)) return _SendResult.drop;

    final sessionId = _collectorSessionId;
    if (sessionId == null || sessionId.isEmpty) return _SendResult.retry;
    _stampCollectorIds(events, sessionId);

    try {
      final response = await _postJson('/v1/events/batch', {'events': events});

      final result = _classifyResponse(response.statusCode);
      if (_isCurrentEpoch(epoch)) {
        _lastEventPostUnanswered = false;
        _noteRequestOutcome('/v1/events/batch', result, response.statusCode);
      }
      return result;
    } catch (error) {
      if (_isCurrentEpoch(epoch)) {
        _lastEventPostUnanswered = true;
        _noteRequestError('/v1/events/batch', error);
      }
      return _SendResult.retry;
    }
  }

  /// Stamps the collector session id, and traits id once known, at send time.
  void _stampCollectorIds(List<Map<String, Object?>> events, String sessionId) {
    final traitsId = _traitsId;
    for (final event in events) {
      event['sessionId'] = sessionId;
      if (traitsId != null && traitsId.isNotEmpty) {
        event['traitsId'] = traitsId;
      }
    }
  }

  /// Records the first failure of a session or event post per outage, and
  /// its recovery. Frame uploads report through `collector_frame_upload`.
  void _noteRequestOutcome(String path, _SendResult result, int statusCode) {
    if (result == _SendResult.accepted) {
      if (!_failingRequestPaths.remove(path)) return;
      _recordDiagnostic('collector-request', {
        'component': 'collector_request',
        'path': path,
        'result': 'recovered',
      });
      return;
    }
    _reportRequestFailure(path, {'statusCode': statusCode});
  }

  void _noteRequestError(String path, Object error) {
    _reportRequestFailure(path, {
      'error': error is TimeoutException ? 'timeout' : 'transport',
    });
  }

  void _reportRequestFailure(String path, Map<String, Object?> detail) {
    if (!_failingRequestPaths.add(path)) return;
    _recordDiagnostic('collector-request', {
      'component': 'collector_request',
      'path': path,
      'result': 'failed',
      ...detail,
    });
  }

  Future<void> _flushOnce() async {
    final epoch = _sessionEpoch;
    final timing = _FlushTiming();
    await timing.step('sessions', _flushLifecyclePosts);
    // Never upload events or frames until the collector session id is known.
    if (_isCurrentEpoch(epoch) && _hasCollectorSessionId) {
      await _flushFramesAndEvents(timing, epoch);
    }
    _reportSlowFlush(timing, epoch);
  }

  Future<void> _flushFramesAndEvents(_FlushTiming timing, int epoch) async {
    // Upload visual evidence before publishing events that reference frame IDs.
    // Session completion may trigger inspection as soon as those events arrive.
    await timing.step('frames', _flushFrames);
    if (_retryBatches.isNotEmpty) {
      // Try the retry head once, but keep draining fresh events below.
      await timing.step('event_retries', _flushRetryBatches);
    }
    if (_eventLaneUnanswered) {
      // The retry head got no response at all, so the endpoint is down or
      // hung and a fresh batch would only wait out another timeout. A batch
      // the collector rejects gets a status back, so fresh events still go
      // out behind it; one that hangs the collector holds them in the retry
      // queue until it is evicted.
      _parkPendingEvents(_pendingEvents.length);
      return;
    }
    await _drainPendingEvents(timing, epoch);
  }

  /// Whether the event lane is waiting on a retry head whose last post got
  /// no response (timeout or transport error).
  bool get _eventLaneUnanswered =>
      _retryBatches.isNotEmpty && _lastEventPostUnanswered;

  /// Drains only the events queued when this pass reached them. Events keep
  /// arriving in a busy session; later ones go to the next pass so the loop
  /// cannot keep frames waiting indefinitely.
  Future<void> _drainPendingEvents(_FlushTiming timing, int epoch) async {
    var remaining = _pendingEvents.length;
    while (remaining > 0 &&
        _pendingEvents.isNotEmpty &&
        _isCurrentEpoch(epoch)) {
      final sent = await timing.step('events', _flushEventBatch);
      remaining -= sent.count;
      if (sent.retry) {
        // The endpoint is failing or hung, so every further batch would wait
        // out its own timeout. Park this pass's other events instead.
        _parkPendingEvents(remaining);
        return;
      }
      // Frames captured while that batch was in flight go before the next
      // batch, which may reference them. A failing frame lane waits for the
      // next pass instead of stalling every batch behind its timeout.
      if (!_framesNeedRetry) await timing.step('frames', _flushFrames);
    }
  }

  /// Reports the first slow pass of an outage. The outage ends with a fast
  /// pass once nothing is waiting for a retry; a pass that fails fast on a
  /// flaky network does not end it.
  void _reportSlowFlush(_FlushTiming timing, int epoch) {
    if (!_isCurrentEpoch(epoch)) return;
    final elapsed = timing.elapsed;
    if (elapsed < _slowFlushThreshold) {
      if (!_awaitingRetry) _slowFlushReported = false;
      return;
    }
    if (_slowFlushReported) return;
    _slowFlushReported = true;
    _recordDiagnostic('collector-flush', {
      'component': 'collector_flush',
      'result': 'slow',
      'durationMs': elapsed.inMilliseconds,
      'step': timing.slowestStep,
      'stepDurationMs': timing.slowestStepDuration.inMilliseconds,
    });
  }

  /// Whether any lane still holds work the collector has not accepted.
  bool get _awaitingRetry =>
      _framesNeedRetry ||
      _retryBatches.isNotEmpty ||
      _pendingLifecycle.isNotEmpty;

  Future<void> _flushFrames() async {
    if (_pendingFrames.isEmpty) return;
    final epoch = _sessionEpoch;
    final sessionId = _collectorSessionId;
    // Confirm the current collector session before draining so frames queued
    // for a newer session cannot be taken by a stale in-flight flush.
    if (sessionId == null || sessionId.isEmpty || !_isCurrentEpoch(epoch)) {
      return;
    }

    // Take one batch at a time and upload only the frames present now. The
    // rest stay pending under maxPendingFrames / maxPendingFrameBytes, so at
    // most one batch is held beyond those bounds, and frames captured during
    // the drain wait for the next pass instead of extending this one.
    var remaining = _pendingFrames.length;
    var droppedBatch = false;
    while (remaining > 0 && _pendingFrames.isNotEmpty) {
      final batch = _takeFrameBatch();
      remaining -= batch.length;
      final result = await _processFrameBatch(sessionId, batch, epoch);
      _inFlightFrames -= batch.length;
      // A session reset mid-flush drops the batch rather than sending it
      // under a stale collector id.
      if (!_isCurrentEpoch(epoch)) {
        _settleStaleFrames(batch, result);
        return;
      }
      if (result.retry) {
        _framesNeedRetry = true;
        _forgetFinishedFrames(batch.sublist(0, result.retryOffset));
        _requeueFailedUploads(batch.sublist(result.retryOffset));
        return;
      }
      _forgetFinishedFrames(batch);
      droppedBatch = droppedBatch || result.dropped;
    }
    _noteFrameLaneHealthy(droppedBatch);
  }

  /// Frame counterpart of [_settleStaleRequest]: frames from `retryOffset` on
  /// were left to retry, or never sent, and will not be requeued.
  void _settleStaleFrames(
    List<_PendingFrameUpload> batch,
    ({bool retry, bool dropped, int retryOffset}) result,
  ) {
    if (result.retry) _droppedTotal += batch.length - result.retryOffset;
  }

  static const _frameBatchSize = 20;

  /// Removes and returns the oldest pending frames, up to one upload batch.
  List<_PendingFrameUpload> _takeFrameBatch() {
    _pendingFrames.sort((a, b) => a.frameNo.compareTo(b.frameNo));
    final count = _pendingFrames.length < _frameBatchSize
        ? _pendingFrames.length
        : _frameBatchSize;
    final batch = _pendingFrames.sublist(0, count);
    _pendingFrames.removeRange(0, count);
    _inFlightFrames += count;
    return batch;
  }

  void _noteFrameLaneHealthy(bool droppedBatch) {
    _framesNeedRetry = false;
    if (_frameUploadFailureReported && !droppedBatch) {
      _recordUploadDiagnostic('recovered', null, 0);
      _frameUploadFailureReported = false;
    }
  }

  Future<({bool retry, bool dropped, int retryOffset})> _processFrameBatch(
    String sessionId,
    List<_PendingFrameUpload> batch,
    int epoch,
  ) async {
    final result = await _sendFrameBatch(sessionId, batch);
    if (!_isCurrentEpoch(epoch)) {
      // Reported so the caller can count frames that will not be retried.
      final retry = result.result == _SendResult.retry;
      return (retry: retry, dropped: false, retryOffset: 0);
    }
    if (result.result == _SendResult.retry) {
      _reportFrameUploadFailure(result.statusCode, batch.length);
      return (retry: true, dropped: false, retryOffset: 0);
    }
    if (result.result == _SendResult.drop &&
        result.statusCode == 400 &&
        batch.length > 1) {
      _reportFrameUploadFailure(result.statusCode, batch.length);
      return _isolateRejectedFrames(sessionId, batch, epoch);
    }
    if (result.result == _SendResult.drop) {
      _reportFrameUploadFailure(result.statusCode, batch.length);
      return (retry: false, dropped: true, retryOffset: 0);
    }
    return (retry: false, dropped: false, retryOffset: 0);
  }

  Future<({bool retry, bool dropped, int retryOffset})> _isolateRejectedFrames(
    String sessionId,
    List<_PendingFrameUpload> batch,
    int epoch,
  ) async {
    var dropped = false;
    // A single invalid capture must not discard its valid neighbors.
    for (var index = 0; index < batch.length; index++) {
      final result = await _sendFrameBatch(sessionId, [batch[index]]);
      if (!_isCurrentEpoch(epoch)) {
        // The rest of the batch will not be sent: report it for counting.
        final unsent = result.result == _SendResult.retry ? index : index + 1;
        return (retry: true, dropped: dropped, retryOffset: unsent);
      }
      if (result.result == _SendResult.retry) {
        _reportFrameUploadFailure(result.statusCode, 1);
        return (retry: true, dropped: dropped, retryOffset: index);
      }
      if (result.result == _SendResult.drop) {
        dropped = true;
        _reportFrameUploadFailure(result.statusCode, 1);
      }
    }
    return (retry: false, dropped: dropped, retryOffset: 0);
  }

  Future<({_SendResult result, int? statusCode})> _sendFrameBatch(
    String sessionId,
    List<_PendingFrameUpload> uploads,
  ) async {
    try {
      final response = await _sendTimed(
        '/v1/frames',
        (abortTrigger) => _frameUploadRequest(sessionId, uploads, abortTrigger),
      );
      return (
        result: _classifyResponse(response.statusCode),
        statusCode: response.statusCode,
      );
    } catch (_) {
      return (result: _SendResult.retry, statusCode: null);
    }
  }

  Future<http.Response> _postJson(String path, Object body) {
    return _sendTimed(
      path,
      (abortTrigger) =>
          http.AbortableRequest(
              'POST',
              _baseUri.resolve(path),
              abortTrigger: abortTrigger,
            )
            ..headers.addAll(_CollectorHttpClient._jsonHeaders)
            ..body = jsonEncode(body),
    );
  }

  /// Sends one collector request and aborts it once [_requestTimeout]
  /// passes. Giving up on the future alone would leave the socket open, and
  /// the request body (up to a batch of frames) held, until the OS times the
  /// connection out; a retry would then open another. Throws
  /// [TimeoutException] on timeout.
  Future<http.Response> _sendTimed(
    String path,
    http.BaseRequest Function(Future<void> abortTrigger) build,
  ) {
    final abort = Completer<void>();
    return _tracedResponse(
      path,
      () async =>
          http.Response.fromStream(await _client.send(build(abort.future))),
    ).timeout(
      _requestTimeout,
      onTimeout: () {
        abort.complete();
        throw TimeoutException('collector request timed out', _requestTimeout);
      },
    );
  }

  http.MultipartRequest _frameUploadRequest(
    String sessionId,
    List<_PendingFrameUpload> uploads,
    Future<void> abortTrigger,
  ) {
    final request = http.AbortableMultipartRequest(
      'POST',
      _baseUri.resolve('/v1/frames'),
      abortTrigger: abortTrigger,
    );
    request.fields['sessionId'] = sessionId;
    request.fields['frameNos'] = uploads
        .map((upload) => upload.frameNo.toString())
        .join(',');
    for (final upload in uploads) {
      request.files.add(
        http.MultipartFile.fromBytes(
          'files',
          upload.bytes,
          filename: '${upload.frameNo}.jpg',
          contentType: MediaType('image', 'jpeg'),
        ),
      );
    }
    request.fields['frameMetadata'] = jsonEncode(
      uploads.map((upload) => upload.metadata).toList(),
    );
    return request;
  }

  void _reportFrameUploadFailure(int? statusCode, int frameCount) {
    if (_frameUploadFailureReported) return;
    _frameUploadFailureReported = true;
    _recordUploadDiagnostic('failed', statusCode, frameCount);
  }

  void _recordUploadDiagnostic(String result, int? statusCode, int frameCount) {
    _recordDiagnostic('collector-frame-upload', {
      'component': 'collector_frame_upload',
      'result': result,
      if (statusCode != null) 'statusCode': statusCode,
      'frameCount': frameCount,
      'droppedFrameCount': _droppedFrameCount,
      'droppedReferencedFrameCount': _droppedReferencedFrameCount,
    });
  }

  /// Queues a bounded `capture_diagnostic` event. [data] must never carry
  /// image contents, payloads, or credentials.
  void _recordDiagnostic(String idPrefix, Map<String, Object?> data) {
    final session = _session;
    if (session == null) return;
    final event = TugboatEvent(
      id: '$idPrefix-${_diagnosticSequence++}',
      atMs: _elapsedMs(),
      type: 'capture_diagnostic',
      data: data,
    );
    _pendingEvents.add(
      mapTugboatEventToCollectorEvent(
        event: event,
        sessionStartedAt: session.startedAt,
        collectorConfig: _config,
        userId: _userId,
      ),
    );
    _trimPendingEvents();
  }

  /// Frames that left the queue (uploaded, rejected, or evicted) no longer
  /// need eviction protection.
  void _forgetFinishedFrames(Iterable<_PendingFrameUpload> frames) {
    for (final frame in frames) {
      _referencedFrameNos.remove(frame.frameNo);
      _finishedFrameNos.add(frame.frameNo);
    }
    while (_finishedFrameNos.length > _config.maxPendingFrames) {
      _finishedFrameNos.remove(_finishedFrameNos.first);
    }
  }

  @visibleForTesting
  int get referencedFrameCount => _referencedFrameNos.length;

  void _requeueFailedUploads(List<_PendingFrameUpload> uploads) {
    // Keep failed uploads within the configured memory bound. Diagnostics
    // record any evictions so downstream consumers can see the evidence gap.
    _pendingFrames.insertAll(0, uploads);
    _trimPendingFrames();
  }

  void _trimPendingEvents() {
    if (_pendingEvents.length <= _config.maxPendingEvents) return;
    final dropped = _pendingEvents.length - _config.maxPendingEvents;
    _pendingEvents.removeRange(0, dropped);
    _droppedTotal += dropped;
    debugPrint(
      '[tugboat] collector dropped $dropped pending event(s) due to backpressure',
    );
  }

  void _trimPendingFrames() {
    var bytes = 0;
    for (final frame in _pendingFrames) {
      bytes += frame.bytes.length;
    }
    var dropped = 0;
    while (_pendingFrames.isNotEmpty &&
        (_pendingFrames.length > _config.maxPendingFrames ||
            bytes > _config.maxPendingFrameBytes)) {
      final evicted = _pendingFrames.removeAt(_frameEvictionIndex());
      bytes -= evicted.bytes.length;
      dropped += 1;
      if (_referencedFrameNos.contains(evicted.frameNo)) {
        _droppedReferencedFrameCount += 1;
      }
      _forgetFinishedFrames([evicted]);
    }
    if (dropped == 0) return;
    _droppedTotal += dropped;
    _droppedFrameCount += dropped;
    if (_droppedFrameCount >= _nextDropReportAt) {
      while (_nextDropReportAt <= _droppedFrameCount) {
        _nextDropReportAt *= 2;
      }
      _recordDropDiagnostic();
    }
    debugPrint(
      '[tugboat] collector dropped $dropped pending frame(s) due to backpressure',
    );
  }

  /// Oldest frame no event references, else the oldest frame. The newest
  /// frame is kept: the event that points at it usually arrives just after.
  int _frameEvictionIndex() {
    for (var index = 0; index < _pendingFrames.length - 1; index++) {
      if (!_referencedFrameNos.contains(_pendingFrames[index].frameNo)) {
        return index;
      }
    }
    return 0;
  }

  void _recordDropDiagnostic() {
    _reportedDroppedFrameCount = _droppedFrameCount;
    _recordUploadDiagnostic('dropped', null, _droppedFrameCount);
  }

  _SendResult _classifyResponse(int statusCode) {
    if (statusCode == 202) return _SendResult.accepted;
    if (_shouldRetry(statusCode)) return _SendResult.retry;
    return _SendResult.drop;
  }

  bool _shouldRetry(int statusCode) =>
      statusCode == 408 || statusCode == 429 || statusCode >= 500;

  Future<http.Response> _tracedResponse(
    String path,
    Future<http.Response> Function() send,
  ) async {
    if (!_httpProofEnabled) return send();
    final stopwatch = Stopwatch()..start();
    try {
      final response = await send();
      _logHttpProof(
        path: path,
        statusCode: response.statusCode,
        durationMs: stopwatch.elapsedMilliseconds,
      );
      return response;
    } catch (error) {
      _logHttpProof(
        path: path,
        durationMs: stopwatch.elapsedMilliseconds,
        error: error,
      );
      rethrow;
    }
  }

  void _logHttpProof({
    required String path,
    int? statusCode,
    required int durationMs,
    Object? error,
  }) {
    debugPrint(
      formatCollectorHttpProofLine(
        path: path,
        localSessionId: _session?.id,
        returnedSessionId: _collectorSessionId,
        statusCode: statusCode,
        durationMs: durationMs,
        error: error,
      ),
    );
  }
}

enum _SendResult { accepted, retry, drop }

/// Wall-clock time spent per step of one flush pass.
class _FlushTiming {
  final Stopwatch _total = Stopwatch()..start();
  final Map<String, Duration> _steps = {};

  Duration get elapsed => _total.elapsed;

  String get slowestStep => _slowest?.key ?? 'none';

  Duration get slowestStepDuration => _slowest?.value ?? Duration.zero;

  MapEntry<String, Duration>? get _slowest {
    MapEntry<String, Duration>? slowest;
    for (final entry in _steps.entries) {
      if (slowest == null || entry.value > slowest.value) slowest = entry;
    }
    return slowest;
  }

  Future<T> step<T>(String name, Future<T> Function() run) async {
    final stopwatch = Stopwatch()..start();
    try {
      return await run();
    } finally {
      _steps[name] = (_steps[name] ?? Duration.zero) + stopwatch.elapsed;
    }
  }
}

class _CollectorHttpClient extends http.BaseClient {
  _CollectorHttpClient({
    required http.Client inner,
    required String apiKey,
    required String platform,
    required String buildNumber,
    required String versionName,
    required String appId,
  }) : _inner = inner,
       _defaultHeaders = {
         'X-PMKit-API-Key': apiKey,
         'X-Tugboat-API-Key': apiKey,
         'X-Platform': platform,
         'X-App-Build': buildNumber,
         'X-App-Version': versionName,
         'X-App-Id': appId,
         'X-Sdk-Version': tugboatSdkVersion,
       };

  static const _jsonHeaders = {'Content-Type': 'application/json'};

  final http.Client _inner;
  final Map<String, String> _defaultHeaders;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    for (final entry in _defaultHeaders.entries) {
      request.headers.putIfAbsent(entry.key, () => entry.value);
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

/// A moment in a session: [at] is the wall-clock time, for absolute
/// timestamps, and [elapsed] the monotonic time since the session started.
typedef _Trigger = ({DateTime at, Duration elapsed});

class _PendingSessionLifecycle {
  const _PendingSessionLifecycle({
    required this.eventType,
    required this.triggeredAt,
    required this.atMs,
    this.activeLocale,
  });

  final String eventType;
  final DateTime triggeredAt;

  /// Milliseconds since the session started, from the monotonic clock.
  final int atMs;
  final TugboatLocaleInfo? activeLocale;
}

class _PendingFrameUpload {
  const _PendingFrameUpload({
    required this.frameNo,
    required this.bytes,
    required this.metadata,
  });

  final int frameNo;
  final Uint8List bytes;
  final Map<String, Object?> metadata;
}
