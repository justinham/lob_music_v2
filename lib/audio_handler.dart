import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';

/// Minimal AudioPlayerHandler bridging just_audio to audio_service.
/// Live notification + Bluetooth controls.
class LobMusicHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer _player;
  final OnAudioQuery _audioQuery;

  LobMusicHandler(this._player, this._audioQuery) {

    // Stream player events → system notification
_player.playbackEventStream.map(_transformEvent).pipe(playbackState);
// Current song index → update MediaItem
    _player.currentIndexStream.listen((index) {
        if (index != null) {
        _updateNowPlaying(index);
      }
    });
  }

  AudioProcessingState _mapProcessingState(ProcessingState state) {
    switch (state) {
      case ProcessingState.idle: return AudioProcessingState.idle;
      case ProcessingState.loading: return AudioProcessingState.loading;
      case ProcessingState.buffering: return AudioProcessingState.buffering;
      case ProcessingState.ready: return AudioProcessingState.ready;
      case ProcessingState.completed: return AudioProcessingState.completed;
    }
  }

  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        _player.playing ? MediaControl.pause : MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 3],
      processingState: _mapProcessingState(_player.processingState),
      playing: _player.playing,
      updatePosition: _player.position,
    );
  }

  Future<void> _updateNowPlaying(int index) async {
    final queue = _player.audioSource as ConcatenatingAudioSource?;
    if (queue == null || index >= queue.length) return;

    final source = queue.children[index];
    if (source is! UriAudioSource) return;
    final uri = source.uri.toString();

    final songs = await _audioQuery.querySongs(
      sortType: SongSortType.TITLE,
      orderType: OrderType.ASC_OR_SMALLER,
      uriType: UriType.EXTERNAL,
      ignoreCase: true,
    );
    SongModel? song;
    try {
      song = songs.firstWhere((s) => s.uri == uri);
    } catch (_) {
      if (songs.isNotEmpty) song = songs.first;
    }
    if (song != null) {
        mediaItem.add(MediaItem(
        id: uri,
        title: song.title,
        artist: song.artist ?? 'Unknown',
        album: song.album ?? 'Unknown',
        duration: Duration(milliseconds: song.duration ?? 0),
      ));
    }
  }

  @override
  Future<void> play()  => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> stop() => _player.stop();
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> skipToNext() => _player.seekToNext();
  @override
  Future<void> skipToPrevious() => _player.seekToPrevious();

  @override
  Future<void> skipToQueueItem(int index) async {
    await _player.seek(Duration.zero, index: index);
  }

  /// Called by main.dart when a new playlist is loaded so we can set the queue.
  void setQueue(List<MediaItem> items) {
    queue.add(items);
  }
}