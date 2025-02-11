import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_editor/utils/styles.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter_ffmpeg/statistics.dart';
import 'package:flutter_ffmpeg/flutter_ffmpeg.dart';

enum RotateDirection { left, right }

///A preset is a collection of options that will provide a certain encoding speed to compression ratio.
///
///A slower preset will provide better compression (compression is quality per filesize).
///
///This means that, for example, if you target a certain file size or constant bit rate,
///you will achieve better quality with a slower preset.
///Similarly, for constant quality encoding,
///you will simply save bitrate by choosing a slower preset.
enum VideoExportPreset {
  none,
  ultrafast,
  superfast,
  veryfast,
  faster,
  fast,
  medium,
  slow,
  slower,
  veryslow
}

class VideoEditorController extends ChangeNotifier {
  ///Style for [TrimSlider]
  final TrimSliderStyle trimStyle;

  ///Style for [CropGridViewer]
  final CropGridStyle cropStyle;

  ///Video from [File].
  final File file;

  ///Constructs a [VideoEditorController] that edits a video from a file.
  VideoEditorController.file(
    this.file, {
    TrimSliderStyle trimStyle,
    CropGridStyle cropStyle,
  })  : assert(file != null),
        _video = VideoPlayerController.file(file),
        this.cropStyle = cropStyle ?? CropGridStyle(),
        this.trimStyle = trimStyle ?? TrimSliderStyle();

  FlutterFFmpeg _ffmpeg = FlutterFFmpeg();
  FlutterFFprobe _ffprobe = FlutterFFprobe();

  int _rotation = 0;
  bool isTrimming = false;
  bool isCropping = false;

  ///Get the **MinTrim** (Range is `0.0` to `1.0`).
  double minTrim = 0.0;

  ///Get the **MaxTrim** (Range is `0.0` to `1.0`).
  double maxTrim = 1.0;

  ///The **TopLeft Offset** (Range is `Offset(0.0, 0.0)` to `Offset(1.0, 1.0)`).
  Offset minCrop = Offset.zero;

  ///The **BottomRight Offset** (Range is `Offset(0.0, 0.0)` to `Offset(1.0, 1.0)`).
  Offset maxCrop = Offset(1.0, 1.0);

  ///The **TopLeft Offset Limit** (Range is `Offset(0.0, 0.0)` to `Offset(1.0, 1.0)`).
  Offset minCropLimit = Offset.zero;

  ///The **BottomRight Offset Limit** (Range is `Offset(0.0, 0.0)` to `Offset(1.0, 1.0)`).
  Offset maxCropLimit = Offset(1.0, 1.0);

  double preferredCropAspectRatio;

  Duration _trimEnd = Duration.zero;
  Duration _trimStart = Duration.zero;
  VideoPlayerController _video;

  int _videoWidth = 0;
  int _videoHeight = 0;

  ///Get the `VideoPlayerController`
  VideoPlayerController get video => _video;

  ///Get the `VideoPlayerController.value.initialized`
  bool get initialized => _video.value.initialized;

  ///Get the `VideoPlayerController.value.isPlaying`
  bool get isPlaying => _video.value.isPlaying;

  ///Get the `VideoPlayerController.value.position`
  Duration get videoPosition => _video.value.position;

  ///Get the `VideoPlayerController.value.duration`
  Duration get videoDuration => _video.value.duration;

  Size get videoDimension =>
      Size(_videoWidth.toDouble(), _videoHeight.toDouble());

  //----------------//
  //VIDEO CONTROLLER//
  //----------------//
  ///Attempts to open the given [File] and load metadata about the video.
  Future<void> initialize() async {
    await _video.initialize();
    await _getVideoDimensions();
    _video.addListener(_videoListener);
    _video.setLooping(true);
    _updateTrimRange();
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    if (isPlaying) _video?.pause();
    _video.removeListener(_videoListener);
    _video.dispose();
    _video = null;
    final executions = await _ffmpeg.listExecutions();
    if (executions.length > 0) await _ffmpeg.cancel();
    _ffprobe = null;
    _ffmpeg = null;
    super.dispose();
  }

  void _videoListener() {
    if (videoPosition < _trimStart || videoPosition >= _trimEnd)
      _video.seekTo(_trimStart);
    notifyListeners();
  }

  Future<void> _getVideoDimensions() async {
    final info = await _ffprobe.getMediaInformation(file.path);
    final streams = info.getStreams();

    if (streams != null && streams.length > 0) {
      for (var stream in streams) {
        final width = stream.getAllProperties()['width'];
        final height = stream.getAllProperties()['height'];
        if (width != null && width > _videoWidth) _videoWidth = width;
        if (height != null && height > _videoHeight) _videoHeight = height;
      }
    }
  }

  //----------//
  //VIDEO CROP//
  //----------//
  String _getCrop() {
    final end = Offset(_videoWidth * maxCrop.dx, _videoHeight * maxCrop.dy);
    final start = Offset(_videoWidth * minCrop.dx, _videoHeight * minCrop.dy);
    return "crop=${end.dx - start.dx}:${end.dy - start.dy}:${start.dx}:${start.dy}";
  }

  ///Update minCrop and maxCrop.
  ///Arguments range are `Offset(0.0, 0.0)` to `Offset(1.0, 1.0)`.
  void updateCrop(Offset min, Offset max) {
    minCrop = min;
    maxCrop = max;
    notifyListeners();
  }

  //----------//
  //VIDEO TRIM//
  //----------//
  ///Update minTrim and maxTrim. Arguments range are `0.0` to `1.0`.
  void updateTrim(double min, double max) {
    minTrim = min;
    maxTrim = max;
    _updateTrimRange();
    notifyListeners();
  }

  void _updateTrimRange() {
    _trimEnd = videoDuration * maxTrim;
    _trimStart = videoDuration * minTrim;
  }

  ///Get the **VideoPosition** (Range is `0.0` to `1.0`).
  double get trimPosition =>
      videoPosition.inMilliseconds / videoDuration.inMilliseconds;

  ///Don't touch this >:)

  //------------//
  //VIDEO ROTATE//
  //------------//
  void rotate90Degrees([RotateDirection direction = RotateDirection.right]) {
    switch (direction) {
      case RotateDirection.left:
        _rotation += 90;
        if (_rotation >= 360) _rotation = _rotation - 360;
        break;
      case RotateDirection.right:
        _rotation -= 90;
        if (_rotation <= 0) _rotation = 360 + _rotation;
        break;
    }
    notifyListeners();
  }

  String _getRotation() {
    List<String> transpose = [];
    for (int i = 0; i < _rotation / 90; i++) transpose.add("transpose=2");
    return transpose.length > 0 ? "${transpose.join(',')}" : "";
  }

  int get rotation => _rotation;

  //------------//
  //VIDEO EXPORT//
  //------------//
  ///Export the video at `TemporaryDirectory` and return a `File`.
  ///
  ///
  ///If the [name] is `null`, then it uses the filename.
  ///
  ///
  ///The [scaleVideo] is `scale=width*scale:height*scale` and reduce o increase video size.
  ///
  ///The [progressCallback] is called while the video is exporting. This argument is usually used to update the export progress percentage.
  ///
  ///The [preset] is the `compress quality` **(Only available on full-lts package)**.
  ///A slower preset will provide better compression (compression is quality per filesize).
  ///**More info about presets**:  https://ffmpeg.org/ffmpeg-formats.htmlhttps://trac.ffmpeg.org/wiki/Encode/H.264
  Future<File> exportVideo({
    String name,
    String format = "mp4",
    double scale = 1.0,
    String customInstruction,
    void Function(Statistics) progressCallback,
    VideoExportPreset preset = VideoExportPreset.none,
  }) async {
    final FlutterFFmpegConfig _config = FlutterFFmpegConfig();
    final String tempPath = (await getTemporaryDirectory()).path;
    final String videoPath = file.path.replaceAll(' ',"\$");
    if (name == null) name = path.basename(videoPath).split('.')[0];
    final String outputPath = tempPath + name + ".$format";

    //-----------------//
    //CALCULATE FILTERS//
    //-----------------//
    final String gif = format != "gif" ? "" : "fps=10 -loop 0";
    final String trim =
        minTrim == 0.0 && maxTrim == 1.0 ? "" : "-ss $_trimStart -to $_trimEnd";
    final String crop =
        minCrop == Offset.zero && maxCrop == Offset(1.0, 1.0) ? "" : _getCrop();
    final String rotation =
        _rotation >= 360 || _rotation <= 0 ? "" : _getRotation();
    final String scaleInstruction =
        scale == 1.0 ? "" : "scale=iw*$scale:ih*$scale";

    //----------------//
    //VALIDATE FILTERS//
    //----------------//
    final List<String> filters = [crop, scaleInstruction, rotation, gif];
    filters.removeWhere((item) => item.isEmpty);
    final String filter =
        filters.isNotEmpty ? "-filter:v " + filters.join(",") : "";
    final String execute =
        " -i $videoPath ${customInstruction ?? ""} $filter ${_getPreset(preset)} $trim -y $outputPath";

    if (progressCallback != null)
      _config.enableStatisticsCallback(progressCallback);
    final int code = await _ffmpeg.execute(execute);
    _config.enableStatisticsCallback(null);

    //------//
    //RESULT//
    //------//
    if (code == 0) {
      print("SUCCESS EXPORT AT $outputPath");
      return File(outputPath);
    } else if (code == 255) {
      print("USER CANCEL EXPORT");
      return null;
    } else {
      print("ERROR ON EXPORT VIDEO (CODE $code)");
      return null;
    }
  }

  String _getPreset(VideoExportPreset preset) {
    String newPreset = "medium";

    switch (preset) {
      case VideoExportPreset.ultrafast:
        newPreset = "ultrafast";
        break;
      case VideoExportPreset.superfast:
        newPreset = "superfast";
        break;
      case VideoExportPreset.veryfast:
        newPreset = "veryfast";
        break;
      case VideoExportPreset.faster:
        newPreset = "faster";
        break;
      case VideoExportPreset.fast:
        newPreset = "fast";
        break;
      case VideoExportPreset.medium:
        newPreset = "medium";
        break;
      case VideoExportPreset.slow:
        newPreset = "slow";
        break;
      case VideoExportPreset.slower:
        newPreset = "slower";
        break;
      case VideoExportPreset.veryslow:
        newPreset = "veryslow";
        break;
      case VideoExportPreset.none:
        break;
    }

    return preset == VideoExportPreset.none ? "" : "-preset $newPreset";
  }
}
