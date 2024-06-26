import "dart:async";
import "dart:math";

import "package:http/http.dart" as http;
import "package:mapplet/src/common/extensions.dart";
import "package:mapplet/src/common/logger.dart";
import "package:mapplet/src/database/depot_database.dart";
import "package:mapplet/src/database/models/tile_model.dart";
import "package:mapplet/src/depot/depot_config.dart";
import "package:meta/meta.dart";
import "package:queue/queue.dart";
import "package:quiver/iterables.dart";

/// Fetch operation progress model
class FetchProgress {
  FetchProgress({
    required this.progress,
    required this.sizeByte,
  });

  /// The current amount of bytes fetched
  final int sizeByte;

  /// Progress of the fetch operation
  final double progress;
}

@internal
class TileFetchReport {
  TileFetchReport({required this.sizeByte});

  final int sizeByte;
}

enum AbortReason { manual, fetchTimeout, fullStorage}

/// Handles the fetch operation of a region.
///
/// Copies the [DepotConfiguration] of the corresponding [Depot].
///
/// Fetches the tiles in parallel and writes on the database in batches. The size of the batches is defined by the [DepotConfiguration.fetchMaxHeapSizeMiB] and the level of parallelism by [DepotConfiguration.fetchMaxWorkers]
class FetchOperation {
  FetchOperation({
    required DepotDatabase db,
    required this.regionId,
    required this.urls,
    required this.config,
  }) : _db = db;
  final DepotDatabase _db;

  final DepotConfiguration config;
  final String regionId;
  http.Client client = http.Client();
  final Iterable<String> urls;
  Queue? _workersQueue;
  bool _fetching = false;
  StreamController? _operationGate;
  AbortReason? _abortReason;
  // ignore: close_sinks
  final StreamController<AbortReason> _abortStreamController = StreamController.broadcast();
  // ignore: close_sinks
  final StreamController<Future<bool>> _commitStreamController = StreamController.broadcast();

  /// Get notifications on when the fetch operations is aborted
  Stream<AbortReason> get onAbort => _abortStreamController.stream;

  /// Get notifications on when the fetch operations is committed to the database
  ///
  /// The stream passes the future that completes with the result of the commit in the database
  Stream<Future<bool>> get onCommit => _commitStreamController.stream;

  Future<void> _fetcher({
    required Iterable<String> urls,
    required StreamController gate,
    required StreamController<TileFetchReport> fetchReport,
    double maxHeapSizeMib = 8,
  }) async {
    var fetched = List<TileModel>.empty(growable: true);
    var storedTiles = await _db.getTilesByUrl(urls);
    int retry = 0;
    int size = 0;
    for (int i = 0; i < storedTiles.length; i++) {
      var url = urls.elementAt(i);
      TileModel? res = storedTiles.elementAt(i);
      while (res == null && retry < config.fetchTileAttempts) {
        try {
          final http.Response response = await client.get(Uri.parse(url)).timeout(config.fetchTileTimeout ?? const Duration(seconds: 5));
          res = TileModel.factory(url, response.bodyBytes);
        } catch (error) {
          if (error is TimeoutException) {
            log("tile fetch timeout");
          } else {
            log("error on fetcher: $error");
          }
          res = null;
        }
        if (gate.isClosed) return;
        retry++;
      }
      if (res == null) {
        _abortReason = AbortReason.fetchTimeout;
        return Future.error("failed to fetch tile, $retry attempts");
      }
      //logDebug("tile fetched, ${retry} tries");
      fetched.add(res);
      fetchReport.sink.add(TileFetchReport(sizeByte: res.bytes.length));
      size += res.bytes.length;
      final dbSize = (await _db.getStats()).byteSize;
      if (dbSize + size > config.maxSizeMiB.mibToByte()) {
        _abortReason = AbortReason.fullStorage;
        return Future.error("Depot storage is full");
      }
      retry = 0;
      if (size.byteToMib() >= maxHeapSizeMib) {
        _db.enqueueBatchWriteTx(fetched.toList());
        fetched.clear();
        size = 0;
      }
    }
    _db.enqueueBatchWriteTx(fetched.toList());
  }

  int _computeThreadCount(int tiles) => min([(1 / pow(tiles + 1, -0.375)).floor(), config.fetchMaxWorkers])!;

  /// Abort the currently active operation, if any
  ///
  /// If [purgeUnlinkedTiles] is true, clean all the tiles that have no region linked
  ///
  /// Note that preventing unlinked tiles to be deleted allows future fetch operations on the same tiles to recognize that they are already present on the database, greatly speeding up the operation at the cost of database space
  Future<void> abort({bool purgeUnlinkedTiles = true}) async {
    _operationGate?.close();
    try {
      _workersQueue?.cancel();
    } catch (_) {}
    await _db.cleanTemp(purgeUnlinkedTiles: purgeUnlinkedTiles);
    log("fetch operation aborted");
    _abortStreamController.sink.add(_abortReason ?? AbortReason.manual);
  }

  /// Start the fetch operation
  Stream<FetchProgress> fetch() async* {
    if (_fetching) return;
    _db.cleanTemp(purgeUnlinkedTiles: false);

    var threadCount = _computeThreadCount(urls.length);
    var batchSize = urls.length ~/ threadCount;
    var threadMaxHeapSizeMib = config.fetchMaxHeapSizeMiB / threadCount;
    log(
      "${urls.length} tiles, $threadCount workers with batches of $batchSize, max heap size ${config.fetchMaxHeapSizeMiB.toStringAsFixed(2)} MiB, ${threadMaxHeapSizeMib.toStringAsFixed(2)} MiB per worker",
    );
    _abortReason = null;
    _fetching = true;
    _operationGate = StreamController.broadcast();
    _workersQueue = Queue(parallel: threadCount);

    var completed = 0;
    var cumulativeSizeByte = 0;

    client = http.Client();
    bool aborted = false;
    StreamController<TileFetchReport> tileFetchController = StreamController.broadcast();

    for (final partition in partition(urls, batchSize)) {
      _workersQueue!
          .add(
        () => _fetcher(
          urls: partition,
          gate: _operationGate!,
          fetchReport: tileFetchController,
          maxHeapSizeMib: threadMaxHeapSizeMib,
        ),
      )
          .onError((error, stackTrace) {
        if (error is! QueueCancelledException) {
          log("fetcher error $error, aborting operation");
          aborted = true;
          abort();
        }
      });
    }
    await for (final tileReport in tileFetchController.stream) {
      completed++;
      cumulativeSizeByte += tileReport.sizeByte;
      var progress = FetchProgress(
        progress: completed / urls.length,
        sizeByte: cumulativeSizeByte,
      );
      yield progress;
      if (completed >= urls.length) break;
    }

    if (!aborted) {
      var commit = _db.commitRegionTx(regionId);
      _commitStreamController.sink.add(commit);
      await commit;
    }
    tileFetchController.close();
    _fetching = false;
  }
}
