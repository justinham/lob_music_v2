import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'audio_handler.dart';

late AudioPlayer globalPlayer;
late LobMusicHandler globalHandler;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  globalPlayer = AudioPlayer();
  globalHandler = LobMusicHandler(globalPlayer, OnAudioQuery());
  await AudioService.init(
    builder: () => globalHandler,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.justinh.lob.lob_music.channel.audio',
      androidNotificationChannelName: 'Lob Music Playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );
  runApp(const LobMusicApp());
}

class LobMusicApp extends StatelessWidget {
  const LobMusicApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lob Music',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple, brightness: Brightness.dark),
      ),
      home: const MusicHome(),
    );
  }
}

class AlbumModel {
  final int id;
  final String name;
  final String artist;
  final List<SongModel> songs;
  AlbumModel({required this.id, required this.name, required this.artist, required this.songs});
}

class MusicHome extends StatefulWidget {
  const MusicHome({super.key});
  @override
  State<MusicHome> createState() => _MusicHomeState();
}

class _MusicHomeState extends State<MusicHome> {
  AudioPlayer get _player => globalPlayer;
  final OnAudioQuery _audioQuery = OnAudioQuery();

  bool _permissionGranted = false;
  bool _isLoading = true;
  bool _showFullPlayer = false;
  bool _isShuffled = false;
  bool _isRepeating = false;
  bool _hasLoadedPlaylist = false;  // true once an album is loaded and ready to play
  bool _isCardView = false; // true=card stack, false=horizontal list view
  bool _showSearch = false;
  bool _showCloud = false;

  // Cloud downloader state
  List<String> _cloudFiles = [];
  final Map<String, double> _cloudDownloadProgress = {};
  final Set<String> _cloudDownloading = {};
  final Set<String> _cloudDeleting = {};
  String _cloudStatus = '';
  final _dio = Dio();
  static const _cloudServerUrl = 'http://10.0.0.48:8099';
  static const _deleteChannel = MethodChannel('lob_music/delete');
  String _searchQuery = '';

  List<SongModel> _allSongs = [];
  List<AlbumModel> _albums = [];
  int _cardIndex = 0;       // which album is "on top" (center, opaque)
  double _dragOffset = 0;   // for smooth swipe animation
  int _currentIndex = 0;
  String? _selectedAlbumId;  // currently open album
  List<int> _playNextQueue = [];  // play-next queue (hardest - deferred)

  // Gesture strip
  double _stripDx = 0;
  double _stripStartX = 0;

  // Disc rotation (full player)
  double _discRotation = 0;
  double _lastAngle = 0;
  bool _isDraggingDisc = false;

  // Full player slide animation
  double _playerSlideOffset = 1.0;  // 0 = fully open, 1 = fully closed
  bool _isDraggingPlayer = false;

  double _calculateAngle(Offset pos, Offset center) {
    return atan2(pos.dy - center.dy, pos.dx - center.dx);
  }

  @override
  void initState() {
    super.initState();
    _requestPermissionAndLoad();
    _player.currentIndexStream.listen((i) {
      if (i != null && mounted) setState(() => _currentIndex = i);
    });
    _player.playerStateStream.listen((s) {
      if (mounted) setState(() {});
      // Drain queue when song completes
      if (s.processingState == ProcessingState.completed && _playNextQueue.isNotEmpty) {
        final nextIndex = _playNextQueue.removeAt(0);
        _player.seek(Duration.zero, index: nextIndex);
        _player.play();
        setState(() => _currentIndex = nextIndex);
      }
    });
  }

  @override
  void dispose() {
    // _player.dispose(); // global player — do not dispose here
    super.dispose();
  }

  Future<void> _requestPermissionAndLoad() async {
    final t0 = DateTime.now();
    try {
      var status = await Permission.audio.status;
      if (!status.isGranted) {
        status = await Permission.audio.request();
      }
      if (!status.isGranted) {
        status = await Permission.storage.request();
      }
      _permissionGranted = status.isGranted;
      if (_permissionGranted) {
        await _loadSongs();
      }
    } catch (e) {
      _permissionGranted = false;
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _loadSongs() async {
    final t0 = DateTime.now();
    try {
      final songs = await _audioQuery.querySongs(
        sortType: SongSortType.TITLE,
        orderType: OrderType.ASC_OR_SMALLER,
        uriType: UriType.EXTERNAL,
        ignoreCase: true,
      );
      songs.removeWhere((s) => s.duration == null || s.duration! < 30000);

    final Map<String, List<SongModel>> albumMap = {};
    final Map<String, int> albumIdMap = {};
    for (var s in songs) {
      final album = s.album ?? 'Unknown Album';
      albumMap.putIfAbsent(album, () => []).add(s);
      if (!albumIdMap.containsKey(album)) albumIdMap[album] = s.id;
    }

    _albums = albumMap.entries.map((e) => AlbumModel(
      id: albumIdMap[e.key]!,
      name: e.key,
      artist: e.value.first.artist ?? 'Unknown Artist',
      songs: e.value,
    )).toList();

    _allSongs = songs;
    } catch (e) {
      _albums = [];
      _allSongs = [];
    }
  }

  void _addToPlayNext(int index) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('▶ "${_allSongs[index].title}" will play next',
          style: const TextStyle(color: Colors.white, fontSize: 12)),
        backgroundColor: Colors.deepPurple.shade800,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showPlayNextMenu(int index, SongModel song) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(song.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(song.artist ?? 'Unknown', style: const TextStyle(color: Colors.white54, fontSize: 14)),
              const SizedBox(height: 20),
              ListTile(
                leading: const Icon(Icons.queue_music, color: Colors.deepPurpleAccent),
                title: const Text('Play Next', style: TextStyle(color: Colors.white)),
                subtitle: const Text('Play immediately after current song', style: TextStyle(color: Colors.white38, fontSize: 12)),
                onTap: () {
                  Navigator.pop(ctx);
                  _addToPlayNext(index);
                },
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.playlist_add, color: Colors.deepPurpleAccent),
                title: const Text('Add to Queue', style: TextStyle(color: Colors.white)),
                subtitle: const Text('Add to end of queue', style: TextStyle(color: Colors.white38, fontSize: 12)),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() => _playNextQueue.add(index));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('✓ "${song.title}" added to queue',
                      style: const TextStyle(color: Colors.white, fontSize: 12)),
                      backgroundColor: Colors.green.shade800,
                      duration: const Duration(seconds: 2)),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showQueueSheet() {
    final album = _albums.cast<AlbumModel?>().firstWhere((a) => a?.id.toString() == _selectedAlbumId, orElse: () => null);
    if (album == null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                const Icon(Icons.queue_music, color: Colors.deepPurpleAccent, size: 20),
                const SizedBox(width: 8),
                Text('Queue (${_playNextQueue.length})', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                const Spacer(),
                if (_playNextQueue.isNotEmpty)
                  TextButton(
                    onPressed: () { Navigator.pop(ctx); setState(() => _playNextQueue.clear()); },
                    child: const Text('Clear all', style: TextStyle(color: Colors.red, fontSize: 13)),
                  ),
              ]),
              const SizedBox(height: 8),
              if (_playNextQueue.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('Queue is empty', style: TextStyle(color: Colors.white24, fontSize: 14)),
                )
              else
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.4),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _playNextQueue.length,
                    itemBuilder: (ctx, i) {
                      final idx = _playNextQueue[i];
                      final song = album.songs[idx];
                      return Dismissible(
                        key: Key('queue_$i'),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          color: Colors.red.shade900,
                          child: const Icon(Icons.delete, color: Colors.white, size: 20),
                        ),
                        onDismissed: (_) { setState(() => _playNextQueue.removeAt(i)); },
                        confirmDismiss: (_) async {
                          return await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              backgroundColor: const Color(0xFF1A1A2E),
                              title: const Text('Remove from queue?', style: TextStyle(color: Colors.white)),
                              content: Text('Remove "${song.title}" from queue?', style: const TextStyle(color: Colors.white70)),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove', style: TextStyle(color: Colors.red))),
                              ],
                            ),
                          ) ?? false;
                        },
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.deepPurple.withAlpha(30),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(children: [
                            Container(width: 32, height: 32, decoration: BoxDecoration(color: Colors.deepPurple, borderRadius: BorderRadius.circular(8)),
                              child: Center(child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)))),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 13)),
                                Text(song.artist ?? 'Unknown', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                              ]),
                            ),
                            const Icon(Icons.drag_handle, color: Colors.white24, size: 18),
                          ]),
                        ),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }


  Future<void> _openAlbum(AlbumModel album) async {
    final t0 = DateTime.now();
    _selectedAlbumId = album.id.toString();
    final sources = album.songs.asMap().entries.map((e) =>
      AudioSource.uri(Uri.parse(e.value.uri!), tag: {'title': e.value.title, 'artist': e.value.artist})
    ).toList();
    await _player.setAudioSource(ConcatenatingAudioSource(children: sources));
    _hasLoadedPlaylist = true;
    _playNextQueue.clear();
    setState(() {});

    // Defer queue sync and playback so AudioService is fully initialized
    Future.delayed(const Duration(milliseconds: 300), () {
      final items = album.songs.asMap().entries.map((e) => MediaItem(
        id: e.value.uri!,
        title: e.value.title,
        artist: e.value.artist ?? 'Unknown',
        album: album.name,
        duration: Duration(milliseconds: e.value.duration ?? 0),
      )).toList();
      try { AudioService.updateQueue(items); } catch (e) {}
      _player.play();
    });
  }

  Future<void> _playSong(int index) async {
    if (_selectedAlbumId == null) return;
    if (_playNextQueue.isNotEmpty) {
      final nextIndex = _playNextQueue.removeAt(0);
      await _player.seek(Duration.zero, index: nextIndex);
      await _player.play();
      setState(() => _currentIndex = nextIndex);
      return;
    }
    await _player.seek(Duration.zero, index: index);
    await _player.play();
    setState(() => _currentIndex = index);
  }

  void _onStripHorizontalDrag(double dx) {
    final w = MediaQuery.of(context).size.width;
    if (dx.abs() > w * 0.25) {
      if (dx > 0) _player.seekToPrevious();
      else _player.seekToNext();
      _stripDx = 0;
    }
  }

  void _animatePlayerOpen(bool open) {
    setState(() => _playerSlideOffset = open ? 0.0 : 1.0);
  }

  String _formatDuration(int? ms) {
    if (ms == null) return '--:--';
    final d = Duration(milliseconds: ms);
    return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D1A),
      body: SafeArea(
        child: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (_showSearch) {
              setState(() { _showSearch = false; _searchQuery = ''; });
              return;
            }
            if (_playerSlideOffset < 0.5) {
              _animatePlayerOpen(false);
              return;
            }
            if (_showCloud) {
              setState(() => _showCloud = false);
              return;
            }
          },
          child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : !_permissionGranted
                ? const Center(child: Text('Storage permission required', style: TextStyle(color: Colors.white)))
                : Stack(children: [
                    Column(children: [
                      _buildTopBar(),
                      if (_showSearch)
                        Expanded(child: _buildSearchOverlay())
                      else
                        Expanded(child: Column(children: [
                          if (!_showCloud) ...[
                            _isCardView ? _buildCardStack() : _buildHorizontalAlbumList(),
                            Expanded(child: _buildSongList()),
                            _buildGestureStrip(),
                          ],
                          if (_showCloud) _buildCloudPage(),
                        ])),
                    ]),
                    AnimatedPositioned(
                      duration: _isDraggingPlayer ? Duration.zero : const Duration(milliseconds: 300),
                      curve: Curves.easeOut,
                      left: 0, right: 0, bottom: 0,
                      top: _playerSlideOffset * MediaQuery.of(context).size.height,
                      child: _buildFullPlayerOverlay(),
                    ),
                  ]),
        ),
      ),
    );
  }

  // ============ CLOUD DOWNLOADER ============

  Future<void> _loadCloudFiles() async {
    try {
      final resp = await _dio.get('$_cloudServerUrl/files', options: Options(receiveTimeout: const Duration(seconds: 5)));
      setState(() => _cloudFiles = List<String>.from(resp.data['files'] ?? []));
    } catch (e) {
      setState(() => _cloudFiles = []);
    }
  }

  String _extractVideoId(String url) {
    final patterns = [
      RegExp(r'youtube\.com/watch\?v=([a-zA-Z0-9_-]{11})'),
      RegExp(r'youtu\.be/([a-zA-Z0-9_-]{11})'),
      RegExp(r'youtube\.com/shorts/([a-zA-Z0-9_-]{11})'),
    ];
    for (var p in patterns) {
      final match = p.firstMatch(url);
      if (match != null) return match.group(1)!;
    }
    return '';
  }

  Future<void> _cloudDownload() async {
    final url = await Clipboard.getData(Clipboard.kTextPlain);
    if (url == null || url.text == null || url.text!.trim().isEmpty) return;
    final videoId = _extractVideoId(url.text!.trim());
    if (videoId.isEmpty) {
      setState(() => _cloudStatus = 'Invalid YouTube URL');
      return;
    }
    setState(() => _cloudStatus = 'Downloading to Mac...');
    try {
      final resp = await _dio.post(
        '$_cloudServerUrl/download',
        data: {'url': url.text!.trim()},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      final data = resp.data;
      if (data['error'] != null) {
        setState(() => _cloudStatus = '${data["error"]}');
      } else {
        final filename = data['filename'] ?? 'Done';
        setState(() => _cloudStatus = 'Downloaded! $filename');
        _loadCloudFiles();
      }
    } catch (e) {
      setState(() => _cloudStatus = 'Server error');
    }
  }

  Future<void> _cloudDownloadToPhone(String filename) async {
    _cloudDownloading.add(filename);
    _cloudDownloadProgress[filename] = 0;
    setState(() {});

    try {
      final safeName = Uri.encodeComponent(filename);
      final tmpDir = await getTemporaryDirectory();
      final savePath = '${tmpDir.path}/${DateTime.now().millisecondsSinceEpoch}.mp3';

      await _dio.download(
        '$_cloudServerUrl/file/$safeName',
        savePath,
        options: Options(followRedirects: true, receiveTimeout: const Duration(minutes: 5)),
        onReceiveProgress: (received, total) {
          _cloudDownloadProgress[filename] = total > 0 ? received / total : 0;
          setState(() {});
        },
      );

      final downloadsDir = Directory('/storage/emulated/0/Download');
      if (!await downloadsDir.exists()) await downloadsDir.create(recursive: true);
      await File(savePath).copy('${downloadsDir.path}/$filename');

      _cloudDownloading.remove(filename);
      _cloudDownloadProgress.remove(filename);
      setState(() => _cloudStatus = 'Saved to phone! $filename');
    } catch (e) {
      _cloudDownloading.remove(filename);
      _cloudDownloadProgress.remove(filename);
      setState(() => _cloudStatus = 'Download failed');
    }
  }

  Future<void> _cloudDelete(String filename) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Delete from Mac?', style: TextStyle(color: Colors.white)),
        content: Text('Remove "$filename"?', style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm != true) return;
    _cloudDeleting.add(filename);
    setState(() {});
    try {
      await _dio.delete('$_cloudServerUrl/delete/${Uri.encodeComponent(filename)}');
      _cloudDeleting.remove(filename);
      _loadCloudFiles();
    } catch (e) {
      _cloudDeleting.remove(filename);
      setState(() => _cloudStatus = 'Delete failed');
    }
  }

  Widget _buildCloudPage() {
    return Expanded(
      child: Column(children: [
        // Input row
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A2E),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: TextField(
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: const InputDecoration(
                    hintText: 'Paste YouTube URL here',
                    hintStyle: TextStyle(color: Colors.white24),
                    prefixIcon: Icon(Icons.link, color: Colors.white38, size: 18),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                  ),
                  onSubmitted: (_) => _cloudDownload(),
                ),
              ),
            ),
            const SizedBox(width: 10),
            ElevatedButton(
              onPressed: _cloudDownload,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepPurpleAccent,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Download', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
            ),
          ]),
        ),
        // Status
        if (_cloudStatus.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A2E),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(_cloudStatus, style: const TextStyle(color: Colors.white70, fontSize: 12), textAlign: TextAlign.center),
            ),
          ),
        const SizedBox(height: 8),
        // Header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            const Text('JMusic', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            Text('(${_cloudFiles.length})', style: const TextStyle(color: Colors.white38, fontSize: 14)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.white54, size: 20),
              onPressed: _loadCloudFiles,
            ),
          ]),
        ),
        const SizedBox(height: 4),
        // File list
        Expanded(
          child: _cloudFiles.isEmpty
              ? const Center(child: Text('No downloads yet', style: TextStyle(color: Colors.white24)))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _cloudFiles.length,
                  itemBuilder: (ctx, i) {
                    final filename = _cloudFiles[i];
                    final isDownloading = _cloudDownloading.contains(filename);
                    final isDeleting = _cloudDeleting.contains(filename);
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A2E),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(children: [
                        const Icon(Icons.music_note, color: Colors.deepPurpleAccent, size: 18),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(filename.replaceAll('.mp3', ''), maxLines: 2, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 13)),
                        ),
                        if (isDownloading)
                          SizedBox(width: 24, height: 24,
                            child: CircularProgressIndicator(
                              value: _cloudDownloadProgress[filename],
                              strokeWidth: 2,
                              valueColor: const AlwaysStoppedAnimation(Colors.deepPurpleAccent),
                            ),
                          )
                        else if (isDeleting)
                          const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                        else ...[
                          IconButton(
                            icon: const Icon(Icons.download, color: Colors.white54, size: 18),
                            tooltip: 'Download to phone',
                            onPressed: () => _cloudDownloadToPhone(filename),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.white38, size: 18),
                            tooltip: 'Delete from Mac',
                            onPressed: () => _cloudDelete(filename),
                          ),
                        ],
                      ]),
                    );
                  },
                ),
        ),
      ]),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(children: [
        const Icon(Icons.library_music, color: Colors.white70, size: 18),
        const SizedBox(width: 6),
        const Text('Albums', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
        const Spacer(),
        IconButton(
          icon: Icon(Icons.cloud_download, color: _showCloud ? Colors.deepPurpleAccent : Colors.white54, size: 20),
          tooltip: 'Cloud downloader',
          onPressed: () { setState(() => _showCloud = !_showCloud); if (_showCloud) _loadCloudFiles(); },
          padding: const EdgeInsets.all(6), constraints: const BoxConstraints(),
        ),
        const SizedBox(width: 4),
        IconButton(
          icon: Icon(_isCardView ? Icons.view_carousel : Icons.view_week, color: Colors.white54, size: 20),
          tooltip: _isCardView ? 'List' : 'Cards',
          onPressed: () => setState(() => _isCardView = !_isCardView),
          padding: const EdgeInsets.all(6), constraints: const BoxConstraints(),
        ),
        const SizedBox(width: 4),
        IconButton(
          icon: const Icon(Icons.search, color: Colors.white54, size: 20),
          tooltip: 'Search',
          onPressed: () => setState(() => _showSearch = true),
          padding: const EdgeInsets.all(6), constraints: const BoxConstraints(),
        ),
        const SizedBox(width: 4),
        IconButton(
          icon: Icon(Icons.shuffle, color: _isShuffled ? Colors.deepPurpleAccent : Colors.white54, size: 20),
          onPressed: () async { _isShuffled = !_isShuffled; await _player.setShuffleModeEnabled(_isShuffled); setState(() {}); },
          padding: const EdgeInsets.all(6), constraints: const BoxConstraints(),
        ),
        const SizedBox(width: 4),
        IconButton(
          icon: Icon(Icons.repeat, color: _isRepeating ? Colors.deepPurpleAccent : Colors.white54, size: 20),
          onPressed: () async { _isRepeating = !_isRepeating; await _player.setLoopMode(_isRepeating ? LoopMode.one : LoopMode.off); setState(() {}); },
          padding: const EdgeInsets.all(6), constraints: const BoxConstraints(),
        ),
        const SizedBox(width: 4),
        IconButton(
          icon: Icon(Icons.queue_music, color: _playNextQueue.isNotEmpty ? Colors.deepPurpleAccent : Colors.white54, size: 20),
          onPressed: () => _showQueueSheet(),
          padding: const EdgeInsets.all(6), constraints: const BoxConstraints(),
        ),
      ]),
    );
  }

  Widget _buildCardStack() {
    if (_albums.isEmpty) return const SizedBox(height: 230, child: Center(child: Text('No albums', style: TextStyle(color: Colors.white54))));
    final total = _albums.length;
    final screenW = MediaQuery.of(context).size.width;
    final centerX = screenW / 2;

    return SizedBox(
      height: 230,
      child: GestureDetector(
        onHorizontalDragUpdate: (d) => setState(() => _dragOffset += d.delta.dx),
        onHorizontalDragEnd: (d) {
          final threshold = 80.0;
          if (_dragOffset < -threshold) {
            setState(() => _cardIndex = (_cardIndex + 1) % total);
          } else if (_dragOffset > threshold) {
            setState(() => _cardIndex = (_cardIndex - 1 + total) % total);
          }
          _dragOffset = 0;
        },
        child: Stack(
          alignment: Alignment.center,
          children: List.generate(total, (i) {
            final anglePerCard = 2 * 3.14159 / total;
            final baseAngle = (i - _cardIndex) * anglePerCard;
            final dragAngle = _dragOffset / screenW * 2 * 3.14159;
            final angle = baseAngle + dragAngle;

            final radius = screenW / 3.2;
            final x = centerX + radius * sin(angle);
            final yOffset = radius * 0.25 * (1 - cos(angle));

            var normAngle = angle;
            while (normAngle > 3.14159) normAngle -= 2 * 3.14159;
            while (normAngle < -3.14159) normAngle += 2 * 3.14159;

            final frontWeight = 1.0 - normAngle.abs() / 3.14159;
            final scale = frontWeight * 0.35 + 0.6;
            final opacity = frontWeight * 0.8 + 0.05;
            final isFront = frontWeight > 0.85;

            return Positioned(
              left: x - 80,
              top: 15 + yOffset,
              child: IgnorePointer(
                ignoring: !isFront,
                child: Opacity(
                  opacity: isFront ? 1.0 : opacity.clamp(0.0, 1.0),
                  child: GestureDetector(
                    onTap: isFront ? () => _openAlbum(_albums[i]) : null,
                    child: Transform.scale(
                      scale: scale,
                      child: Container(
                        width: 160, height: 200,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              HSLColor.fromAHSL(1, (i * 37.0) % 360, 0.65, 0.4).toColor(),
                              HSLColor.fromAHSL(1, (i * 37.0 + 40) % 360, 0.65, 0.25).toColor(),
                            ],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withAlpha((frontWeight > 0.5 ? 100 : 40).toInt()),
                              blurRadius: frontWeight > 0.5 ? 20 : 6,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Container(
                            width: 64, height: 64,
                            decoration: BoxDecoration(
                              color: Colors.white.withAlpha(20),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.album, color: Colors.white70, size: 36),
                          ),
                          const SizedBox(height: 12),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text(
                              _albums[i].name,
                              maxLines: 2,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                shadows: frontWeight > 0.75 ? [const Shadow(color: Colors.black38, blurRadius: 6)] : null,
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _albums[i].artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: Colors.white.withAlpha((frontWeight * 200 + 40).toInt()), fontSize: 11),
                          ),
                          Text(
                            '${_albums[i].songs.length} songs',
                            style: TextStyle(color: Colors.white.withAlpha((frontWeight * 130 + 20).toInt()), fontSize: 10),
                          ),
                        ]),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildCarouselCard(int albumIdx, int offset) {
    final total = _albums.length;
    if (albumIdx < 0 || albumIdx >= total) return const SizedBox();

    final screenW = MediaQuery.of(context).size.width;
    final radius = screenW / 3.2;
    final spacing = 65.0;
    final centerX = screenW / 2 - 80;

    // Only front card (offset=0) receives events
    final isFront = offset == 0;

    // During drag, all cards move together
    final posX = centerX + offset * spacing + _dragOffset;
    final yOff = (offset.abs() * 5).toDouble();
    final scale = 1.0 - offset.abs() * 0.15;
    final opacity = isFront ? 1.0 : (1.0 - offset.abs() * 0.25).clamp(0.1, 0.6);

    return Positioned(
      left: posX,
      top: 15 - yOff,
      child: IgnorePointer(
        ignoring: !isFront,
        child: Opacity(
          opacity: opacity,
          child: GestureDetector(
            onTap: isFront ? () => _openAlbum(_albums[albumIdx]) : null,
            child: Transform.scale(
              scale: scale,
              child: Container(
                width: 160, height: 200,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      HSLColor.fromAHSL(1, (albumIdx * 37.0) % 360, 0.65, 0.4).toColor(),
                      HSLColor.fromAHSL(1, (albumIdx * 37.0 + 40) % 360, 0.65, 0.25).toColor(),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(isFront ? 100 : 60),
                      blurRadius: isFront ? 20 : 10,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Container(
                    width: 64, height: 64,
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(20),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.album, color: Colors.white70, size: 36),
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      _albums[albumIdx].name,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        shadows: isFront ? [const Shadow(color: Colors.black38, blurRadius: 6)] : null,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _albums[albumIdx].artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                  Text(
                    '${_albums[albumIdx].songs.length} songs',
                    style: const TextStyle(color: Colors.white54, fontSize: 10),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHorizontalAlbumList() {
    if (_albums.isEmpty) return const SizedBox(height: 180, child: Center(child: Text('No albums', style: TextStyle(color: Colors.white54))));
    return SizedBox(
      height: 200,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _albums.length,
        itemBuilder: (ctx, i) {
          final album = _albums[i];
          return GestureDetector(
            onTap: () => _openAlbum(album),
            child: Container(
              width: 140,
              margin: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    HSLColor.fromAHSL(1, (i * 37.0) % 360, 0.65, 0.4).toColor(),
                    HSLColor.fromAHSL(1, (i * 37.0 + 40) % 360, 0.65, 0.25).toColor(),
                  ],
                ),
                boxShadow: [BoxShadow(color: Colors.black.withAlpha(80), blurRadius: 12, offset: const Offset(0, 4))],
              ),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Container(
                  width: 56, height: 56,
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(20),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.album, color: Colors.white70, size: 32),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(album.name, maxLines: 2, textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(height: 4),
                Text(album.artist, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white.withAlpha(150), fontSize: 10)),
                Text('${album.songs.length} songs', style: TextStyle(color: Colors.white.withAlpha(100), fontSize: 9)),
              ]),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSearchOverlay() {
    return Column(children: [
      // Search bar
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(children: [
          Expanded(
            child: TextField(
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 15),
              decoration: InputDecoration(
                hintText: 'Search songs or albums...',
                hintStyle: const TextStyle(color: Colors.white30),
                prefixIcon: const Icon(Icons.search, color: Colors.white38),
                filled: true,
                fillColor: Colors.white.withAlpha(10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              onChanged: (v) => setState(() => _searchQuery = v.toLowerCase()),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white54),
            onPressed: () => setState(() { _showSearch = false; _searchQuery = ''; }),
          ),
        ]),
      ),
      // Results
      Expanded(
        child: _buildSearchResults(),
      ),
    ]);
  }

  Widget _buildSearchResults() {
    if (_searchQuery.isEmpty) {
      return const Center(child: Text('Start typing to search...', style: TextStyle(color: Colors.white24)));
    }

    // Search songs across all albums
    final allSongs = <MapEntry<SongModel, AlbumModel>>[];
    for (var album in _albums) {
      for (var song in album.songs) {
        if (song.title.toLowerCase().contains(_searchQuery) ||
            (song.artist ?? '').toLowerCase().contains(_searchQuery) ||
            album.name.toLowerCase().contains(_searchQuery)) {
          allSongs.add(MapEntry(song, album));
        }
      }
    }

    if (allSongs.isEmpty) {
      return Center(child: Text('No results for "$_searchQuery"', style: const TextStyle(color: Colors.white24)));
    }

    return ListView.builder(
      itemCount: allSongs.length,
      itemBuilder: (ctx, i) {
        final entry = allSongs[i];
        final song = entry.key;
        final album = entry.value;
        return GestureDetector(
          onTap: () {
            _selectedAlbumId = album.id.toString();
            final songIndex = album.songs.indexOf(song);
            _openAlbum(album);
            if (songIndex >= 0) Future.delayed(const Duration(milliseconds: 300), () => _playSong(songIndex));
            setState(() { _showSearch = false; _searchQuery = ''; });
          },
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 16),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(6),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: Colors.deepPurple.withAlpha(80),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.music_note, color: Colors.deepPurpleAccent, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
                  Text('${album.name} • ${song.artist ?? "Unknown"}', maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white38, fontSize: 12)),
                ]),
              ),
              Text(_formatDuration(song.duration), style: const TextStyle(color: Colors.white30, fontSize: 12)),
            ]),
          ),
        );
      },
    );
  }

  Widget _buildSongList() {
    if (_selectedAlbumId == null) {
      return Stack(children: [
        Positioned.fill(
          child: Opacity(
            opacity: 0.15,
            child: Image.asset('assets/gengar.jpg', fit: BoxFit.cover),
          ),
        ),
        const Center(
          child: Padding(
            padding: EdgeInsets.only(top: 320),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text('Tap center card to open album', style: TextStyle(color: Colors.white30, fontSize: 14)),
              SizedBox(height: 4),
              Text('Hold a song to add it to queue', style: TextStyle(color: Colors.white24, fontSize: 12)),
            ]),
          ),
        ),
      ]);
    }
    final album = _albums.firstWhere((a) => a.id.toString() == _selectedAlbumId, orElse: () => _albums.first);
    final songs = album.songs;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(album.name, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                Text(album.artist, style: const TextStyle(color: Colors.white38, fontSize: 12)),
              ]),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white38, size: 20),
              onPressed: () => setState(() { _selectedAlbumId = null; _player.pause(); _hasLoadedPlaylist = false; }),
            ),
          ]),
        ),
        Expanded(
          child: RawScrollbar(
            thumbVisibility: true,
            thumbColor: Colors.deepPurpleAccent,
            thickness: 4,
            radius: const Radius.circular(4),
            child: ListView.builder(
              padding: const EdgeInsets.only(right: 16, bottom: 80, left: 12),
              itemCount: songs.length,
              itemBuilder: (ctx, i) {
              final song = songs[i];
              final isPlaying = _currentIndex == i;
              return Dismissible(
                key: Key(song.id.toString()),
                direction: DismissDirection.endToStart,
                background: Container(
                  margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                  decoration: BoxDecoration(
                    color: Colors.red.shade900,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  child: const Icon(Icons.delete, color: Colors.white, size: 20),
                ),
                confirmDismiss: (dir) async {
                  return await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: const Color(0xFF1A1A2E),
                      title: const Text('Delete song?', style: TextStyle(color: Colors.white)),
                      content: Text('Remove "${song.title}" from device?', style: const TextStyle(color: Colors.white70)),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
                      ],
                    ),
                  ) ?? false;
                },
                onDismissed: (dir) async {
                  try {
                    await _deleteChannel.invokeMethod('deleteSong', {'id': song.id});
                    await _loadSongs();
                    setState(() {});
                  } catch (e) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Delete failed: $e', style: const TextStyle(color: Colors.white, fontSize: 12)),
                        backgroundColor: Colors.red.shade900),
                    );
                  }
                },
                child: GestureDetector(
                  onTap: () => _playSong(i),
                  onLongPress: () => _showPlayNextMenu(i, song),
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: isPlaying ? Colors.deepPurple.withAlpha(60) : Colors.white.withAlpha(6),
                      borderRadius: BorderRadius.circular(12),
                      border: isPlaying ? Border.all(color: Colors.deepPurpleAccent.withAlpha(80)) : null,
                    ),
                    child: Row(children: [
                      Icon(isPlaying ? Icons.play_arrow : Icons.music_note, color: isPlaying ? Colors.deepPurpleAccent : Colors.white38, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: isPlaying ? Colors.deepPurpleAccent : Colors.white, fontSize: 14,
                              fontWeight: isPlaying ? FontWeight.bold : FontWeight.normal)),
                          Text(song.artist ?? 'Unknown', maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white38, fontSize: 12)),
                        ]),
                      ),
                      Text(_formatDuration(song.duration), style: const TextStyle(color: Colors.white30, fontSize: 12)),
                    ]),
                  ),
                ),
              );
            },
          ),
        ),
        ),
      ],
    );
  }

  Widget _buildGestureStrip() {
    AlbumModel? currentAlbum;
    SongModel? currentSong;
    if (_selectedAlbumId != null) {
      currentAlbum = _albums.cast<AlbumModel?>().firstWhere((a) => a?.id.toString() == _selectedAlbumId, orElse: () => null);
      if (currentAlbum != null && currentAlbum.songs.isNotEmpty) {
        currentSong = currentAlbum.songs[_currentIndex.clamp(0, currentAlbum.songs.length - 1)];
      }
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (d) { _stripStartX = d.localPosition.dx; _stripDx = 0; },
      onHorizontalDragUpdate: (d) { setState(() => _stripDx = d.localPosition.dx - _stripStartX); },
      onHorizontalDragEnd: (d) { _onStripHorizontalDrag(_stripDx); _stripDx = 0; setState(() {}); },
      onVerticalDragStart: (_) { _isDraggingPlayer = true; },
      onVerticalDragUpdate: (d) {
        final screenH = MediaQuery.of(context).size.height;
        setState(() { _playerSlideOffset = (_playerSlideOffset + d.primaryDelta! / (screenH * 0.6)).clamp(0.0, 1.0); });
      },
      onVerticalDragEnd: (d) {
        _isDraggingPlayer = false;
        final shouldOpen = d.primaryVelocity != null && d.primaryVelocity! < -200 || _playerSlideOffset < 0.5;
        _animatePlayerOpen(shouldOpen);
      },
      child: Container(
        height: 72,
        decoration: BoxDecoration(
          color: const Color(0xFF161628),
          border: Border(top: BorderSide(color: Colors.deepPurpleAccent.withAlpha(50))),
        ),
        child: SafeArea(
          top: false,
          bottom: true,
          child: Column(children: [
          const SizedBox(height: 8),
          Container(width: 40, height: 3, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 8),
          if (currentSong != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(color: Colors.deepPurple.withAlpha(100), borderRadius: BorderRadius.circular(8)),
                  child: const Icon(Icons.music_note, color: Colors.deepPurpleAccent, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(currentSong.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
                    Text(currentSong.artist ?? 'Unknown', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white38, fontSize: 11)),
                  ]),
                ),
                StreamBuilder<Duration>(
                  stream: _player.positionStream,
                  builder: (ctx, snap) {
                    final pos = snap.data ?? Duration.zero;
                    final dur = _player.duration ?? Duration.zero;
                    return Text(
                      '${_formatDuration(pos.inMilliseconds)} / ${_formatDuration(dur.inMilliseconds)}',
                      style: const TextStyle(color: Colors.white30, fontSize: 10),
                    );
                  },
                ),
                const SizedBox(width: 12),
                StreamBuilder<PlayerState>(
                  stream: _player.playerStateStream,
                  builder: (ctx, snap) {
                    final playing = snap.data?.playing ?? false;
                    return IconButton(
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow, color: Colors.white70, size: 26),
                      onPressed: () => playing ? _player.pause() : _player.play(),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                    );
                  },
                ),
              ]),
            )
          else
            const Padding(padding: EdgeInsets.all(16), child: Text('No song playing', style: TextStyle(color: Colors.white24))),
        ]),
        ),
      ),
    );
  }


  Widget _buildFullPlayerOverlay() {
    AlbumModel? currentAlbum;
    SongModel? currentSong;
    if (_selectedAlbumId != null) {
      currentAlbum = _albums.cast<AlbumModel?>().firstWhere((a) => a?.id.toString() == _selectedAlbumId, orElse: () => null);
      if (currentAlbum != null && currentAlbum.songs.isNotEmpty) {
        currentSong = currentAlbum.songs[_currentIndex.clamp(0, currentAlbum.songs.length - 1)];
      }
    }
    if (currentSong == null) return const SizedBox();

    final state = _player.playerState;

    return Container(
      height: MediaQuery.of(context).size.height,
      color: const Color(0xFF0D0D1A).withAlpha(240),
      child: SafeArea(
        child: Column(children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (_) {},
            onVerticalDragUpdate: (d) {
              final screenH = MediaQuery.of(context).size.height;
              _playerSlideOffset = (_playerSlideOffset + d.primaryDelta! / (screenH * 0.6)).clamp(0.0, 1.0);
            },
            onVerticalDragEnd: (d) {
              final shouldOpen = d.primaryVelocity != null && d.primaryVelocity! < -200 || _playerSlideOffset < 0.5;
              _animatePlayerOpen(shouldOpen);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(children: [
                Container(width: 40, height: 3, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
                const SizedBox(height: 8),
                Row(children: [
                  IconButton(
                    icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white),
                    onPressed: () => _animatePlayerOpen(false),
                  ),
                  const Spacer(),
                  Text(currentAlbum?.name ?? '', style: const TextStyle(color: Colors.white70, fontSize: 13)),
                  const Spacer(),
                  const SizedBox(width: 48),
                ]),
              ]),
            ),
          ),
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (details) {
                  _isDraggingDisc = true;
                  _discRotation = 0;
                  _lastAngle = _calculateAngle(details.localPosition, const Offset(110, 110));
                },
                onPanUpdate: (details) {
                  if (!_isDraggingDisc) return;
                  final currentAngle = _calculateAngle(details.localPosition, const Offset(110, 110));
                  var angleDelta = currentAngle - _lastAngle;
                  if (angleDelta > 3.14159) angleDelta -= 2 * 3.14159;
                  if (angleDelta < -3.14159) angleDelta += 2 * 3.14159;
                  _discRotation += angleDelta;
                  _lastAngle = currentAngle;
                  final seekMs = (_discRotation * 60000 / (2 * 3.14159)).toInt();
                  final newPos = Duration(milliseconds: (_player.position.inMilliseconds + seekMs).clamp(0, (_player.duration?.inMilliseconds ?? 0)));
                  _player.seek(newPos);
                  _discRotation = 0;
                },
                onPanEnd: (details) {
                  _isDraggingDisc = false;
                  _discRotation = 0;
                },
                child: Container(
                  width: 220, height: 220,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [
                      Colors.deepPurple.withAlpha(150),
                      Colors.deepPurple.withAlpha(50),
                    ]),
                    border: Border.all(color: Colors.deepPurpleAccent.withAlpha(80), width: 2),
                    boxShadow: [BoxShadow(color: Colors.deepPurple.withAlpha(80), blurRadius: 40)],
                  ),
                  child: Stack(alignment: Alignment.center, children: [
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: state.playing ? 1 : 0),
                      duration: const Duration(seconds: 3),
                      builder: (ctx, val, child) => Transform.rotate(
                        angle: val * 6.28 * 3,
                        child: Container(
                          width: 200, height: 200,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: SweepGradient(colors: [
                              Colors.white10, Colors.deepPurpleAccent.withAlpha(40),
                              Colors.white10, Colors.deepPurpleAccent.withAlpha(40),
                              Colors.white10,
                            ]),
                          ),
                        ),
                      ),
                    ),
                    Container(
                      width: 80, height: 80,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.deepPurple,
                        border: Border.all(color: Colors.deepPurpleAccent, width: 2),
                      ),
                      child: const Icon(Icons.music_note, color: Colors.white, size: 40),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 32),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(currentSong.title, maxLines: 2, textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 8),
              Text(currentSong.artist ?? 'Unknown', style: const TextStyle(color: Colors.white54, fontSize: 14)),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: StreamBuilder<Duration>(
                  stream: _player.positionStream,
                  builder: (ctx, snap) {
                    final pos = snap.data ?? Duration.zero;
                    final dur = _player.duration ?? Duration.zero;
                    final pct = dur.inMilliseconds > 0 ? pos.inMilliseconds / dur.inMilliseconds : 0.0;
                    return Column(children: [
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: Colors.deepPurpleAccent,
                          inactiveTrackColor: Colors.white12,
                          thumbColor: Colors.deepPurpleAccent,
                          trackHeight: 3,
                        ),
                        child: Slider(
                          value: pct.clamp(0, 1),
                          onChanged: (v) => _player.seek(Duration(milliseconds: (v * dur.inMilliseconds).toInt())),
                        ),
                      ),
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        Text(_formatDuration(pos.inMilliseconds), style: const TextStyle(color: Colors.white30, fontSize: 11)),
                        Text(_formatDuration(dur.inMilliseconds), style: const TextStyle(color: Colors.white30, fontSize: 11)),
                      ]),
                    ]);
                  },
                ),
              ),
              const SizedBox(height: 24),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                IconButton(
                  icon: const Icon(Icons.skip_previous, color: Colors.white, size: 36),
                  onPressed: () => _player.seekToPrevious(),
                ),
                const SizedBox(width: 24),
                GestureDetector(
                  onTap: () => state.playing ? _player.pause() : _player.play(),
                  child: Container(
                    width: 64, height: 64,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.deepPurpleAccent,
                      boxShadow: [BoxShadow(color: Colors.deepPurpleAccent.withAlpha(100), blurRadius: 16)],
                    ),
                    child: Icon(state.playing ? Icons.pause : Icons.play_arrow, color: Colors.white, size: 36),
                  ),
                ),
                const SizedBox(width: 24),
                IconButton(
                  icon: const Icon(Icons.skip_next, color: Colors.white, size: 36),
                  onPressed: () => _player.seekToNext(),
                ),
              ]),
              const SizedBox(height: 16),
              const Text('↻ Rotate disc to seek ↺', style: TextStyle(color: Colors.white24, fontSize: 11)),
            ]),
          ),
        ]),
      ),
    );
  }
}
