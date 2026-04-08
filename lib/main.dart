import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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
  final AudioPlayer _player = AudioPlayer();
  final OnAudioQuery _audioQuery = OnAudioQuery();

  bool _permissionGranted = false;
  bool _isLoading = true;
  bool _showFullPlayer = false;
  bool _isShuffled = false;
  bool _isRepeating = false;
  bool _isCardView = true; // true=card stack, false=horizontal list view

  List<SongModel> _allSongs = [];
  List<AlbumModel> _albums = [];
  int _cardIndex = 0;       // which album is "on top" (center, opaque)
  double _dragOffset = 0;   // for smooth swipe animation
  int _currentIndex = 0;
  String? _selectedAlbumId;  // currently open album

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
    _player.playerStateStream.listen((s) { if (mounted) setState(() {}); });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _requestPermissionAndLoad() async {
    var status = await Permission.audio.status;
    if (!status.isGranted) status = await Permission.audio.request();
    if (!status.isGranted) status = await Permission.storage.request();
    if (status.isGranted) {
      _permissionGranted = true;
      await _loadSongs();
    }
    setState(() => _isLoading = false);
  }

  Future<void> _loadSongs() async {
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
  }

  Future<void> _openAlbum(AlbumModel album) async {
    _selectedAlbumId = album.id.toString();
    final sources = album.songs.asMap().entries.map((e) =>
      AudioSource.uri(Uri.parse(e.value.uri!), tag: {'title': e.value.title, 'artist': e.value.artist})
    ).toList();
    await _player.setAudioSource(ConcatenatingAudioSource(children: sources));
    await _player.play();
    setState(() {});
  }

  Future<void> _playSong(int index) async {
    if (_selectedAlbumId == null) return;
    final album = _albums.firstWhere((a) => a.id.toString() == _selectedAlbumId);
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
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : !_permissionGranted
                ? const Center(child: Text('Storage permission required', style: TextStyle(color: Colors.white)))
                : Stack(children: [
                    Column(children: [
                      _buildTopBar(),
                      _isCardView ? _buildCardStack() : _buildHorizontalAlbumList(),
                      Expanded(child: _buildSongList()),
                      _buildGestureStrip(),
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
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(children: [
        const Icon(Icons.library_music, color: Colors.white70),
        const SizedBox(width: 8),
        const Text('Albums', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(width: 12),
        IconButton(
          icon: Icon(_isCardView ? Icons.view_carousel : Icons.view_week, color: Colors.white54, size: 22),
          tooltip: _isCardView ? 'Switch to list' : 'Switch to cards',
          onPressed: () => setState(() => _isCardView = !_isCardView),
        ),
        const Spacer(),
        IconButton(
          icon: Icon(Icons.shuffle, color: _isShuffled ? Colors.deepPurpleAccent : Colors.white54, size: 22),
          onPressed: () async { _isShuffled = !_isShuffled; await _player.setShuffleModeEnabled(_isShuffled); setState(() {}); },
        ),
        IconButton(
          icon: Icon(Icons.repeat, color: _isRepeating ? Colors.deepPurpleAccent : Colors.white54, size: 22),
          onPressed: () async { _isRepeating = !_isRepeating; await _player.setLoopMode(_isRepeating ? LoopMode.one : LoopMode.off); setState(() {}); },
        ),
      ]),
    );
  }

  Widget _buildCardStack() {
    if (_albums.isEmpty) return const SizedBox(height: 200, child: Center(child: Text('No albums', style: TextStyle(color: Colors.white54))));
    final total = _albums.length;

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
        child: ClipRect(
          child: Center(
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Previous (left, faded)
                _buildAlbumCard((_cardIndex - 1 + total) % total, -1, 0.5, 0.85),
                // Next (right, faded)
                _buildAlbumCard((_cardIndex + 1) % total, 1, 0.5, 0.85),
                // Far left (barely visible)
                _buildAlbumCard((_cardIndex - 2 + total) % total, -2, 0.2, 0.72),
                // Far right (barely visible)
                _buildAlbumCard((_cardIndex + 2) % total, 2, 0.2, 0.72),
                // Center card — TOP, fully opaque, slightly larger
                _buildAlbumCard(_cardIndex, 0, 1.0, 1.0),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAlbumCard(int albumIdx, int offset, double opacity, double scale) {
    final album = _albums[albumIdx];
    // Smooth drag follows center card, side cards snap
    final screenW = MediaQuery.of(context).size.width;
    final cardW = 160.0;
    final spacing = 65.0;
    final centerX = screenW / 2 - cardW / 2;

    return AnimatedPositioned(
      duration: offset == 0 ? Duration.zero : const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      left: centerX + offset * spacing + (offset == 0 ? _dragOffset : 0),
      top: 15 - offset.abs() * 5,
      child: GestureDetector(
        onTap: () {
          if (offset == 0) {
            // Center → open album
            _openAlbum(album);
          } else {
            // Side → bring to center
            setState(() => _cardIndex = albumIdx);
          }
        },
        child: Transform.scale(
          scale: scale,
          child: Opacity(
            opacity: opacity,
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
                    color: Colors.black.withAlpha(offset == 0 ? 100 : 60),
                    blurRadius: offset == 0 ? 20 : 10,
                    offset: Offset(0, 6 + offset.abs() * 2),
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
                    album.name,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      shadows: offset == 0 ? [const Shadow(color: Colors.black38, blurRadius: 6)] : null,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  album.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white.withAlpha(opacity == 1.0 ? 150 : 90), fontSize: 11),
                ),
                Text(
                  '${album.songs.length} songs',
                  style: TextStyle(color: Colors.white.withAlpha(opacity == 1.0 ? 100 : 60), fontSize: 10),
                ),
              ]),
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

  Widget _buildSongList() {
    if (_selectedAlbumId == null) {
      return const Center(child: Text('Tap center card to open album', style: TextStyle(color: Colors.white30, fontSize: 14)));
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
              onPressed: () => setState(() { _selectedAlbumId = null; _player.pause(); }),
            ),
          ]),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: songs.length,
            itemBuilder: (ctx, i) {
              final song = songs[i];
              final isPlaying = _currentIndex == i;
              return GestureDetector(
                onTap: () => _playSong(i),
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
              );
            },
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
      onHorizontalDragStart: (d) { _stripStartX = d.localPosition.dx; _stripDx = 0; },
      onHorizontalDragUpdate: (d) { setState(() => _stripDx = d.localPosition.dx - _stripStartX); },
      onHorizontalDragEnd: (d) { _onStripHorizontalDrag(_stripDx); _stripDx = 0; setState(() {}); },
      onVerticalDragStart: (d) { _isDraggingPlayer = true; },
      onVerticalDragUpdate: (d) {
        if (!_isDraggingPlayer) return;
        // d.primaryDelta is negative when dragging up (towards screen top)
        final screenH = MediaQuery.of(context).size.height;
        setState(() {
          _playerSlideOffset = (_playerSlideOffset + d.primaryDelta! / (screenH * 0.6)).clamp(0.0, 1.0);
        });
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
            // Handle bar
            Padding(
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
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                // Spinning tape — rotate clockwise/counter-clockwise to seek
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
                      // Rotating disc with sweep gradient
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
                      // Center disc
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
                // Progress
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
        ),
      ]),
    );
    );
  }
}
