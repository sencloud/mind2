import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 视频/音频文件的应用内播放。
/// 视频用 media_kit 的 [Video] 组件渲染；音频显示一个简洁的播放控制条。
class MediaPreview extends StatefulWidget {
  const MediaPreview({super.key, required this.path, required this.isVideo});

  final String path;
  final bool isVideo;

  @override
  State<MediaPreview> createState() => _MediaPreviewState();
}

class _MediaPreviewState extends State<MediaPreview> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(MediaPreview old) {
    super.didUpdateWidget(old);
    // 选择了另一个媒体文件时切换播放源。
    if (old.path != widget.path) _open();
  }

  void _open() {
    // 不自动播放，等用户点击播放，避免选中即出声。
    _player.open(Media(Uri.file(widget.path).toString()), play: false);
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isVideo) {
      return Video(controller: _controller);
    }
    return _AudioControls(player: _player);
  }
}

/// 音频的简洁控制条：播放/暂停按钮 + 进度条 + 时间。
class _AudioControls extends StatelessWidget {
  const _AudioControls({required this.player});

  final Player player;

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.audiotrack,
                size: 72, color: Color(0xFFCDCDD2)),
            const SizedBox(height: 20),
            StreamBuilder<Duration>(
              stream: player.stream.position,
              builder: (context, posSnap) {
                final pos = posSnap.data ?? Duration.zero;
                return StreamBuilder<Duration>(
                  stream: player.stream.duration,
                  builder: (context, durSnap) {
                    final dur = durSnap.data ?? Duration.zero;
                    final max = dur.inMilliseconds.toDouble();
                    final value =
                        pos.inMilliseconds.clamp(0, max == 0 ? 1 : max);
                    return Column(
                      children: [
                        Slider(
                          value: value.toDouble(),
                          max: max == 0 ? 1 : max,
                          onChanged: (v) =>
                              player.seek(Duration(milliseconds: v.round())),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(_fmt(pos),
                                  style: const TextStyle(
                                      fontSize: 12, color: Color(0xFF6B6B70))),
                              Text(_fmt(dur),
                                  style: const TextStyle(
                                      fontSize: 12, color: Color(0xFF6B6B70))),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
            const SizedBox(height: 8),
            StreamBuilder<bool>(
              stream: player.stream.playing,
              builder: (context, snap) {
                final playing = snap.data ?? false;
                return IconButton.filled(
                  iconSize: 32,
                  onPressed: player.playOrPause,
                  icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
