import 'dart:async';
import 'dart:convert';
import 'dart:typed_data' show Uint8List;

import 'package:agora_rtc_engine/src/agora_base.dart';
import 'package:agora_rtc_engine/src/agora_media_base.dart';
import 'package:agora_rtc_engine/src/agora_media_engine.dart';
import 'package:agora_rtc_engine/src/agora_media_player.dart';
import 'package:agora_rtc_engine/src/agora_media_recorder.dart';
import 'package:agora_rtc_engine/src/agora_music_content_center.dart';
import 'package:agora_rtc_engine/src/agora_rtc_engine.dart';
import 'package:agora_rtc_engine/src/agora_rtc_engine_ex.dart';
import 'package:agora_rtc_engine/src/agora_rtc_engine_ext.dart';
import 'package:agora_rtc_engine/src/agora_spatial_audio.dart';
import 'package:agora_rtc_engine/src/audio_device_manager.dart';
import 'package:agora_rtc_engine/src/binding/agora_rtc_engine_ex_impl.dart'
    as rtc_engine_ex_binding;
import 'package:agora_rtc_engine/src/binding/agora_rtc_engine_impl.dart'
    as rtc_engine_binding;

import 'package:agora_rtc_engine/src/impl/agora_music_content_center_impl_override.dart'
    as mcci;

import 'package:agora_rtc_engine/src/impl/agora_media_recorder_impl_override.dart'
    as media_recorder_impl;
import 'package:agora_rtc_engine/src/impl/agora_spatial_audio_impl_override.dart'
    as agora_spatial_audio_impl;
import 'package:agora_rtc_engine/src/impl/agora_media_engine_impl_override.dart'
    as media_engine_impl;

import 'package:agora_rtc_engine/src/impl/media_player_impl.dart'
    as media_player_impl;
import 'package:agora_rtc_engine/src/impl/audio_device_manager_impl.dart'
    as audio_device_manager_impl;
import 'package:agora_rtc_engine/src/binding/impl_forward_export.dart';
import 'package:agora_rtc_engine/src/impl/native_iris_api_engine_binding_delegate.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart'
    show
        WidgetsBindingObserver,
        VoidCallback,
        AppLifecycleState,
        WidgetsBinding,
        TargetPlatform,
        debugPrint;
import 'package:iris_method_channel/iris_method_channel.dart';

import 'global_video_view_controller.dart';
import 'package:meta/meta.dart';

// ignore_for_file: public_member_api_docs

/// Borrow from https://github.com/dart-lang/sdk/issues/46264#issuecomment-1151476029
/// Avoid `Warning: Operand of null-aware operation '?.' has type 'WidgetsBinding' which excludes null.`
T? _ambiguate<T>(T? value) => value;

extension RtcEngineExt on RtcEngine {
  GlobalVideoViewController get globalVideoViewController =>
      (this as RtcEngineImpl)._globalVideoViewController;

  ScopedObjects get objectPool => (this as RtcEngineImpl)._objectPool;

  IrisMethodChannel get irisMethodChannel =>
      (this as RtcEngineImpl)._getIrisMethodChannel();
}

extension ThumbImageBufferExt on ThumbImageBuffer {
  ThumbImageBuffer copyWithBuffer(Map<String, dynamic> origanalJson) {
    return ThumbImageBuffer(
      buffer: uint8ListFromPtr(origanalJson['buffer'], length!),
      length: length,
      width: width,
      height: height,
    );
  }
}

extension RtcEngineEventHandlerExExt on RtcEngineEventHandler {
  bool eventIntercept(String event, String eventData, List<Uint8List> buffers) {
    switch (event) {
      case 'RtcEngineEventHandler_onStreamMessageEx':
        if (onStreamMessage == null) break;
        final jsonMap = jsonDecode(eventData);
        RtcEngineEventHandlerOnStreamMessageJson paramJson =
            RtcEngineEventHandlerOnStreamMessageJson.fromJson(jsonMap);
        RtcConnection? connection = paramJson.connection;
        int? remoteUid = paramJson.remoteUid;
        int? streamId = paramJson.streamId;

        int? length = paramJson.length;
        int? sentTs = paramJson.sentTs;

        if (connection == null ||
            remoteUid == null ||
            streamId == null ||
            length == null ||
            sentTs == null) {
          break;
        }
        Uint8List? data = buffers[0];

        onStreamMessage!(connection, remoteUid, streamId, data, length, sentTs);
        return true;
      default:
        break;
    }
    return false;
  }
}

extension MetadataExt on Metadata {
  Metadata copyWith(
      {int? uid, int? size, Uint8List? buffer, int? timeStampMs}) {
    return Metadata(
      uid: uid ?? this.uid,
      size: size ?? this.size,
      buffer: buffer ?? this.buffer,
      timeStampMs: timeStampMs ?? this.timeStampMs,
    );
  }
}

extension MetadataObserverExt on MetadataObserver {
  bool eventIntercept(String event, String data, List<Uint8List> buffers) {
    final jsonMap = jsonDecode(data);
    switch (event) {
      case 'MetadataObserver_onMetadataReceived':
        if (onMetadataReceived == null) break;
        MetadataObserverOnMetadataReceivedJson paramJson =
            MetadataObserverOnMetadataReceivedJson.fromJson(jsonMap);
        Metadata? metadata = paramJson.metadata;

        if (metadata == null) {
          break;
        }

        metadata = Metadata(
          uid: metadata.uid,
          size: metadata.size,
          buffer: buffers[0],
          timeStampMs: metadata.timeStampMs,
        );

        onMetadataReceived!(metadata);
        return true;
      default:
        break;
    }

    return false;
  }
}

class _Lifecycle with WidgetsBindingObserver {
  const _Lifecycle(this.onDestroy);

  final VoidCallback onDestroy;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.detached) {
      onDestroy();
    }
  }
}

class RtcEngineImpl extends rtc_engine_ex_binding.RtcEngineExImpl
    implements RtcEngineEx {
  RtcEngineImpl._(IrisMethodChannel irisMethodChannel)
      : super(irisMethodChannel);

  static RtcEngineImpl? _instance;

  // final IrisMethodChannel irisMethodChannel;

  final _rtcEngineImplScopedKey = const TypedScopedKey(RtcEngineImpl);

  final GlobalVideoViewController _globalVideoViewController =
      GlobalVideoViewController();

  final ScopedObjects _objectPool = ScopedObjects();

  _Lifecycle? _lifecycle;

  @internal
  final MethodChannel engineMethodChannel = const MethodChannel('agora_rtc_ng');

  static RtcEngineEx create() {
    if (_instance != null) return _instance!;

    _instance = RtcEngineImpl._(IrisMethodChannel());

    return _instance!;
  }

  IrisMethodChannel _getIrisMethodChannel() {
    return irisMethodChannel;
  }

  Future<void> _initializeInternal(RtcEngineContext context) async {
    _lifecycle ??= _Lifecycle(
      () {
        release(sync: true);
      },
    );
    // Compatible with 2.10
    // ignore: invalid_null_aware_operator
    _ambiguate(WidgetsBinding.instance)?.addObserver(_lifecycle!);

    await _globalVideoViewController
        .attachVideoFrameBufferManager(irisMethodChannel.getNativeHandle());
  }

  @override
  Future<void> initialize(RtcEngineContext context) async {
    String externalFilesDir = '';
    if (defaultTargetPlatform == TargetPlatform.android) {
      final androidInitResult =
          await engineMethodChannel.invokeMethod('androidInit');
      externalFilesDir = androidInitResult['externalFilesDir'] ?? '';
    }

    await irisMethodChannel
        .initilize(IrisApiEngineNativeBindingDelegateProvider());
    await super.initialize(context);

    await irisMethodChannel.invokeMethod(IrisMethodCall(
      'RtcEngine_setAppType',
      jsonEncode({'appType': 4}),
    ));

    if (externalFilesDir.isNotEmpty) {
      try {
        // Reset the sdk log file to ensure the iris log path has been set
        await setLogFile('$externalFilesDir/agorasdk.log');
      } catch (e) {
        debugPrint(
            '[RtcEngine] setLogFile fail, make sure the permission is granted.');
      }
    }

    await _initializeInternal(context);
  }

  @override
  Future<void> release({bool sync = false}) async {
    if (_instance == null) return;

    if (_lifecycle != null) {
      // Compatible with 2.10
      // ignore: invalid_null_aware_operator
      _ambiguate(WidgetsBinding.instance)?.removeObserver(_lifecycle!);
      _lifecycle = null;
    }

    await _objectPool.clear();

    await _globalVideoViewController
        .detachVideoFrameBufferManager(irisMethodChannel.getNativeHandle());

    await super.release(sync: sync);

    // await apiCaller.disposeAsync();

    await irisMethodChannel.dispose();
    _instance = null;
  }

  @override
  void registerEventHandler(
      covariant RtcEngineEventHandler eventHandler) async {
    final eventHandlerWrapper = RtcEngineEventHandlerWrapper(eventHandler);
    final param = createParams({});

    await irisMethodChannel.registerEventHandler(
        ScopedEvent(
            scopedKey: _rtcEngineImplScopedKey,
            registerName: 'RtcEngine_registerEventHandler',
            unregisterName: 'RtcEngine_unregisterEventHandler',
            handler: eventHandlerWrapper),
        jsonEncode(param));
  }

  @override
  void unregisterEventHandler(
      covariant RtcEngineEventHandler eventHandler) async {
    final eventHandlerWrapper = RtcEngineEventHandlerWrapper(eventHandler);
    final param = createParams({});

    await irisMethodChannel.unregisterEventHandler(
        ScopedEvent(
            scopedKey: _rtcEngineImplScopedKey,
            registerName: 'RtcEngine_registerEventHandler',
            unregisterName: 'RtcEngine_unregisterEventHandler',
            handler: eventHandlerWrapper),
        jsonEncode(param));
  }

  @override
  Future<MediaPlayer> createMediaPlayer() async {
    const apiType = 'RtcEngine_createMediaPlayer';
    final param = createParams({});
    final callApiResult = await irisMethodChannel
        .invokeMethod(IrisMethodCall(apiType, jsonEncode(param)));
    if (callApiResult.irisReturnCode < 0) {
      throw AgoraRtcException(code: callApiResult.irisReturnCode);
    }
    final rm = callApiResult.data;
    final result = rm['result'];

// TODO(littlegnal): Manage the mediaPlayer in scopedObjects
    final MediaPlayer mediaPlayer = media_player_impl.MediaPlayerImpl.create(
        result as int, irisMethodChannel);
    return mediaPlayer;
  }

  @override
  Future<void> destroyMediaPlayer(covariant MediaPlayer mediaPlayer) async {
    const apiType = 'RtcEngine_destroyMediaPlayer';
    final playerId = mediaPlayer.getMediaPlayerId();
    final param = createParams({'playerId': playerId});
    final callApiResult = await irisMethodChannel
        .invokeMethod(IrisMethodCall(apiType, jsonEncode(param)));
    if (callApiResult.irisReturnCode < 0) {
      throw AgoraRtcException(code: callApiResult.irisReturnCode);
    }
    final rm = callApiResult.data;
    final result = rm['result'];
    if (result < 0) {
      throw AgoraRtcException(code: result);
    }
  }

  @override
  Future<void> sendStreamMessage(
      {required int streamId,
      required Uint8List data,
      required int length}) async {
    const apiType = 'RtcEngine_sendStreamMessage';
    final dataPtr = uint8ListToPtr(data);
    final param = createParams(
        {'streamId': streamId, 'data': dataPtr.address, 'length': length});

    final callApiResult = await irisMethodChannel.invokeMethod(
        IrisMethodCall(apiType, jsonEncode(param), buffers: [data]));
    if (callApiResult.irisReturnCode < 0) {
      throw AgoraRtcException(code: callApiResult.irisReturnCode);
    }
    final rm = callApiResult.data;

    freePointer(dataPtr);
    final result = rm['result'];

    if (result < 0) {
      throw AgoraRtcException(code: result);
    }
  }

  @override
  Future<void> enableEncryption(
      {required bool enabled, required EncryptionConfig config}) async {
    const apiType = 'RtcEngine_enableEncryption';
    final configJsonMap = config.toJson();
    if (config.encryptionKdfSalt != null) {
      configJsonMap['encryptionKdfSalt'] = config.encryptionKdfSalt!;
    }

    final param = createParams({'enabled': enabled, 'config': configJsonMap});

    final callApiResult = await irisMethodChannel
        .invokeMethod(IrisMethodCall(apiType, jsonEncode(param)));
    if (callApiResult.irisReturnCode < 0) {
      throw AgoraRtcException(code: callApiResult.irisReturnCode);
    }
    final rm = callApiResult.data;
    final result = rm['result'];
    if (result < 0) {
      throw AgoraRtcException(code: result);
    }
  }

  @override
  Future<void> enableEncryptionEx(
      {required RtcConnection connection,
      required bool enabled,
      required EncryptionConfig config}) async {
    const apiType = 'RtcEngineEx_enableEncryptionEx';
    final configJsonMap = config.toJson();
    if (config.encryptionKdfSalt != null) {
      configJsonMap['encryptionKdfSalt'] = config.encryptionKdfSalt!;
    }

    final param = createParams({
      'connection': connection.toJson(),
      'enabled': enabled,
      'config': configJsonMap
    });

    final callApiResult = await irisMethodChannel
        .invokeMethod(IrisMethodCall(apiType, jsonEncode(param)));
    if (callApiResult.irisReturnCode < 0) {
      throw AgoraRtcException(code: callApiResult.irisReturnCode);
    }
    final rm = callApiResult.data;
    final result = rm['result'];
    if (result < 0) {
      throw AgoraRtcException(code: result);
    }
  }

  @override
  Future<List<ScreenCaptureSourceInfo>> getScreenCaptureSources(
      {required SIZE thumbSize,
      required SIZE iconSize,
      required bool includeScreen}) async {
    const apiType = 'RtcEngine_getScreenCaptureSources';
    final param = createParams({
      'thumbSize': thumbSize.toJson(),
      'iconSize': iconSize.toJson(),
      'includeScreen': includeScreen
    });
    final callApiResult = await irisMethodChannel
        .invokeMethod(IrisMethodCall(apiType, jsonEncode(param)));
    if (callApiResult.irisReturnCode < 0) {
      throw AgoraRtcException(code: callApiResult.irisReturnCode);
    }
    final rm = callApiResult.data;
    final result = rm['result'];
    final sourcesIntPtr = rm['sources'];
    final resultList = List.from(result);
    List<ScreenCaptureSourceInfo> output = [];
    for (final r in resultList) {
      final oldInfo = ScreenCaptureSourceInfo.fromJson(r);

      final newThumbImage = oldInfo.thumbImage!.copyWithBuffer(r['thumbImage']);
      final newIconImage = oldInfo.iconImage!.copyWithBuffer(r['iconImage']);
      final info = ScreenCaptureSourceInfo(
        type: oldInfo.type,
        sourceId: oldInfo.sourceId,
        sourceName: oldInfo.sourceName,
        thumbImage: newThumbImage,
        iconImage: newIconImage,
        processPath: oldInfo.processPath,
        sourceTitle: oldInfo.sourceTitle,
        primaryMonitor: oldInfo.primaryMonitor,
        isOccluded: oldInfo.isOccluded,
      );

      output.add(info);
    }

    await irisMethodChannel.invokeMethod(IrisMethodCall(
        'RtcEngine_releaseScreenCaptureSources',
        jsonEncode({'sources': sourcesIntPtr})));

    return output;
  }

  @override
  Future<void> sendMetaData(
      {required Metadata metadata, required VideoSourceType sourceType}) async {
    assert(metadata.buffer != null);
    const apiType = 'RtcEngine_sendMetaData';
    final dataPtr = uint8ListToPtr(metadata.buffer!);
    final metadataMap = metadata.toJson();
    metadataMap['buffer'] = dataPtr.address;
    final param = createParams(
        {'metadata': metadataMap, 'source_type': sourceType.value()});
    final callApiResult = await irisMethodChannel
        .invokeMethod(IrisMethodCall(apiType, jsonEncode(param)));
    if (callApiResult.irisReturnCode < 0) {
      throw AgoraRtcException(code: callApiResult.irisReturnCode);
    }
    final rm = callApiResult.data;
    freePointer(dataPtr);
    final result = rm['result'];

    if (result < 0) {
      throw AgoraRtcException(code: result);
    }
  }

  @override
  void registerMediaMetadataObserver(
      {required MetadataObserver observer, required MetadataType type}) async {
    final eventHandlerWrapper = MetadataObserverWrapper(observer);
    final param = createParams({'type': type.value()});

    await irisMethodChannel.registerEventHandler(
        ScopedEvent(
            scopedKey: _rtcEngineImplScopedKey,
            registerName: 'RtcEngine_registerMediaMetadataObserver',
            unregisterName: 'RtcEngine_unregisterMediaMetadataObserver',
            handler: eventHandlerWrapper),
        jsonEncode(param));
  }

  @override
  void unregisterMediaMetadataObserver(
      {required MetadataObserver observer, required MetadataType type}) async {
    final eventHandlerWrapper = MetadataObserverWrapper(observer);
    final param = createParams({'type': type.value()});

    await irisMethodChannel.unregisterEventHandler(
        ScopedEvent(
            scopedKey: _rtcEngineImplScopedKey,
            registerName: 'RtcEngine_registerMediaMetadataObserver',
            unregisterName: 'RtcEngine_unregisterMediaMetadataObserver',
            handler: eventHandlerWrapper),
        jsonEncode(param));
  }

  @override
  Future<void> startDirectCdnStreaming(
      {required DirectCdnStreamingEventHandler eventHandler,
      required String publishUrl,
      required DirectCdnStreamingMediaOptions options}) async {
    final eventHandlerWrapper =
        DirectCdnStreamingEventHandlerWrapper(eventHandler);
    final param =
        createParams({'publishUrl': publishUrl, 'options': options.toJson()});

    await irisMethodChannel.registerEventHandler(
        ScopedEvent(
            scopedKey: _rtcEngineImplScopedKey,
            registerName: 'RtcEngine_startDirectCdnStreaming',
            unregisterName: '',
            handler: eventHandlerWrapper),
        jsonEncode(param));
  }

  @override
  VideoDeviceManager getVideoDeviceManager() {
    return VideoDeviceManagerImpl.create(this);
  }

  @override
  AudioDeviceManager getAudioDeviceManager() {
    return audio_device_manager_impl.AudioDeviceManagerImpl.create(this);
  }

  @override
  MediaEngine getMediaEngine() {
    return _objectPool.putIfAbsent<media_engine_impl.MediaEngineImpl>(
        const TypedScopedKey(MediaEngineImpl),
        () => media_engine_impl.MediaEngineImpl.create(irisMethodChannel));
  }

  @override
  MediaRecorder getMediaRecorder() {
    return _objectPool.putIfAbsent<media_recorder_impl.MediaRecorderImpl>(
        const TypedScopedKey(MediaRecorderImpl),
        () => media_recorder_impl.MediaRecorderImpl.create(irisMethodChannel));
  }

  @override
  LocalSpatialAudioEngine getLocalSpatialAudioEngine() {
    return _objectPool
        .putIfAbsent<agora_spatial_audio_impl.LocalSpatialAudioEngineImpl>(
            const TypedScopedKey(LocalSpatialAudioEngineImpl),
            () => agora_spatial_audio_impl.LocalSpatialAudioEngineImpl.create(
                irisMethodChannel));
  }

  @override
  MusicContentCenter getMusicContentCenter() {
    return mcci.MusicContentCenterImpl.create(this);
  }

  @override
  Future<SDKBuildInfo> getVersion() async {
    const apiType = 'RtcEngine_getVersion';
    final param = createParams({});
    final callApiResult = await irisMethodChannel
        .invokeMethod(IrisMethodCall(apiType, jsonEncode(param)));
    if (callApiResult.irisReturnCode < 0) {
      throw AgoraRtcException(code: callApiResult.irisReturnCode);
    }
    final rm = callApiResult.data;
    final result = rm['result'];
    return SDKBuildInfo(version: result, build: rm['build']);
  }

  @override
  Future<void> joinChannel(
      {required String token,
      required String channelId,
      required int uid,
      required ChannelMediaOptions options}) async {
    const apiType = 'RtcEngine_joinChannel2';
    final param = createParams({
      'token': token,
      'channelId': channelId,
      'uid': uid,
      'options': options.toJson()
    });
    final callApiResult = await irisMethodChannel
        .invokeMethod(IrisMethodCall(apiType, jsonEncode(param)));
    if (callApiResult.irisReturnCode < 0) {
      throw AgoraRtcException(code: callApiResult.irisReturnCode);
    }
    final rm = callApiResult.data;
    final result = rm['result'];
    if (result < 0) {
      throw AgoraRtcException(code: result);
    }
  }

  @override
  Future<void> leaveChannel({LeaveChannelOptions? options}) async {
    final apiType =
        options == null ? 'RtcEngine_leaveChannel' : 'RtcEngine_leaveChannel2';
    final param = createParams({'options': options?.toJson()});
    final callApiResult = await irisMethodChannel
        .invokeMethod(IrisMethodCall(apiType, jsonEncode(param)));
    if (callApiResult.irisReturnCode < 0) {
      throw AgoraRtcException(code: callApiResult.irisReturnCode);
    }
    final rm = callApiResult.data;
    final result = rm['result'];
    if (result < 0) {
      throw AgoraRtcException(code: result);
    }
  }

  @override
  Future<void> setClientRole(
      {required ClientRoleType role, ClientRoleOptions? options}) async {
    final apiType = options == null
        ? 'RtcEngine_setClientRole'
        : 'RtcEngine_setClientRole2';
    final param =
        createParams({'role': role.value(), 'options': options?.toJson()});
    final callApiResult = await irisMethodChannel
        .invokeMethod(IrisMethodCall(apiType, jsonEncode(param)));
    if (callApiResult.irisReturnCode < 0) {
      throw AgoraRtcException(code: callApiResult.irisReturnCode);
    }
    final rm = callApiResult.data;
    final result = rm['result'];
    if (result < 0) {
      throw AgoraRtcException(code: result);
    }
  }

  @override
  Future<void> startEchoTest({int intervalInSeconds = 10}) async {
    const apiType = 'RtcEngine_startEchoTest2';
    final param = createParams({'intervalInSeconds': intervalInSeconds});
    final callApiResult = await irisMethodChannel
        .invokeMethod(IrisMethodCall(apiType, jsonEncode(param)));
    if (callApiResult.irisReturnCode < 0) {
      throw AgoraRtcException(code: callApiResult.irisReturnCode);
    }
    final rm = callApiResult.data;
    final result = rm['result'];
    if (result < 0) {
      throw AgoraRtcException(code: result);
    }
  }

  @override
  Future<void> startPreview(
      {VideoSourceType sourceType =
          VideoSourceType.videoSourceCameraPrimary}) async {
    if (_instance == null) return;
    const apiType = 'RtcEngine_startPreview2';
    final param = createParams({'sourceType': sourceType.value()});
    final callApiResult = await irisMethodChannel
        .invokeMethod(IrisMethodCall(apiType, jsonEncode(param)));
    if (callApiResult.irisReturnCode < 0) {
      throw AgoraRtcException(code: callApiResult.irisReturnCode);
    }
    final rm = callApiResult.data;
    final result = rm['result'];
    if (result < 0) {
      throw AgoraRtcException(code: result);
    }
  }

  @override
  Future<void> enableVideo() async {
    if (_instance == null) return;
    super.enableVideo();
  }

  @override
  Future<void> stopPreview(
      {VideoSourceType sourceType =
          VideoSourceType.videoSourceCameraPrimary}) async {
    const apiType = 'RtcEngine_stopPreview2';
    final param = createParams({'sourceType': sourceType.value()});
    final callApiResult = await irisMethodChannel
        .invokeMethod(IrisMethodCall(apiType, jsonEncode(param)));
    if (callApiResult.irisReturnCode < 0) {
      throw AgoraRtcException(code: callApiResult.irisReturnCode);
    }
    final rm = callApiResult.data;
    final result = rm['result'];
    if (result < 0) {
      throw AgoraRtcException(code: result);
    }
  }

  @override
  Future<void> startAudioRecording(AudioRecordingConfiguration config) async {
    const apiType = 'RtcEngine_startAudioRecording3';
    final param = createParams({'config': config.toJson()});
    final callApiResult = await irisMethodChannel
        .invokeMethod(IrisMethodCall(apiType, jsonEncode(param)));
    if (callApiResult.irisReturnCode < 0) {
      throw AgoraRtcException(code: callApiResult.irisReturnCode);
    }
    final rm = callApiResult.data;
    final result = rm['result'];
    if (result < 0) {
      throw AgoraRtcException(code: result);
    }
  }

  @override
  Future<void> startAudioMixing(
      {required String filePath,
      required bool loopback,
      required int cycle,
      int startPos = 0}) async {
    const apiType = 'RtcEngine_startAudioMixing2';
    final param = createParams({
      'filePath': filePath,
      'loopback': loopback,
      'cycle': cycle,
      'startPos': startPos
    });
    final callApiResult = await irisMethodChannel
        .invokeMethod(IrisMethodCall(apiType, jsonEncode(param)));
    if (callApiResult.irisReturnCode < 0) {
      throw AgoraRtcException(code: callApiResult.irisReturnCode);
    }
    final rm = callApiResult.data;
    final result = rm['result'];
    if (result < 0) {
      throw AgoraRtcException(code: result);
    }
  }

  @override
  Future<void> enableDualStreamMode(
      {required bool enabled,
      VideoSourceType sourceType = VideoSourceType.videoSourceCameraPrimary,
      SimulcastStreamConfig? streamConfig}) async {
    final apiType = streamConfig == null
        ? 'RtcEngine_enableDualStreamMode'
        : 'RtcEngine_enableDualStreamMode2';
    final param = createParams({
      'enabled': enabled,
      'sourceType': sourceType.value(),
      'streamConfig': streamConfig?.toJson()
    });
    final callApiResult = await irisMethodChannel
        .invokeMethod(IrisMethodCall(apiType, jsonEncode(param)));
    if (callApiResult.irisReturnCode < 0) {
      throw AgoraRtcException(code: callApiResult.irisReturnCode);
    }
    final rm = callApiResult.data;
    final result = rm['result'];
    if (result < 0) {
      throw AgoraRtcException(code: result);
    }
  }

  @override
  Future<int> createDataStream(DataStreamConfig config) async {
    const apiType = 'RtcEngine_createDataStream2';
    final param = createParams({'config': config.toJson()});
    final callApiResult = await irisMethodChannel
        .invokeMethod(IrisMethodCall(apiType, jsonEncode(param)));
    if (callApiResult.irisReturnCode < 0) {
      throw AgoraRtcException(code: callApiResult.irisReturnCode);
    }
    final rm = callApiResult.data;
    final result = rm['result'];
    if (result < 0) {
      throw AgoraRtcException(code: result);
    }
    final streamIdResult = rm['streamId'];
    return streamIdResult as int;
  }

  @override
  Future<void> addVideoWatermark(
      {required String watermarkUrl, required WatermarkOptions options}) async {
    const apiType = 'RtcEngine_addVideoWatermark2';
    final param = createParams(
        {'watermarkUrl': watermarkUrl, 'options': options.toJson()});
    final callApiResult = await irisMethodChannel
        .invokeMethod(IrisMethodCall(apiType, jsonEncode(param)));
    if (callApiResult.irisReturnCode < 0) {
      throw AgoraRtcException(code: callApiResult.irisReturnCode);
    }
    final rm = callApiResult.data;
    final result = rm['result'];
    if (result < 0) {
      throw AgoraRtcException(code: result);
    }
  }

  @override
  Future<void> joinChannelWithUserAccount(
      {required String token,
      required String channelId,
      required String userAccount,
      ChannelMediaOptions? options}) async {
    final apiType = options == null
        ? 'RtcEngine_joinChannelWithUserAccount'
        : 'RtcEngine_joinChannelWithUserAccount2';
    final param = createParams({
      'token': token,
      'channelId': channelId,
      'userAccount': userAccount,
      'options': options?.toJson()
    });
    final callApiResult = await irisMethodChannel
        .invokeMethod(IrisMethodCall(apiType, jsonEncode(param)));
    if (callApiResult.irisReturnCode < 0) {
      throw AgoraRtcException(code: callApiResult.irisReturnCode);
    }
    final rm = callApiResult.data;
    final result = rm['result'];
    if (result < 0) {
      throw AgoraRtcException(code: result);
    }
  }

  @override
  void registerAudioEncodedFrameObserver(
      {required AudioEncodedFrameObserverConfig config,
      required AudioEncodedFrameObserver observer}) async {
    final eventHandlerWrapper = AudioEncodedFrameObserverWrapper(observer);
    final param = createParams({'config': config.toJson()});

    await irisMethodChannel.registerEventHandler(
        ScopedEvent(
            scopedKey: _rtcEngineImplScopedKey,
            registerName: 'RtcEngine_registerAudioEncodedFrameObserver',
            unregisterName: 'RtcEngine_unregisterAudioEncodedFrameObserver',
            handler: eventHandlerWrapper),
        jsonEncode(param));
  }

  @override
  void unregisterAudioEncodedFrameObserver(
      AudioEncodedFrameObserver observer) async {
    final eventHandlerWrapper = AudioEncodedFrameObserverWrapper(observer);
    final param = createParams({});

    await irisMethodChannel.unregisterEventHandler(
        ScopedEvent(
            scopedKey: _rtcEngineImplScopedKey,
            registerName: 'RtcEngine_registerAudioEncodedFrameObserver',
            unregisterName: 'RtcEngine_unregisterAudioEncodedFrameObserver',
            handler: eventHandlerWrapper),
        jsonEncode(param));
  }

  @override
  void registerAudioSpectrumObserver(AudioSpectrumObserver observer) async {
    final eventHandlerWrapper = AudioSpectrumObserverWrapper(observer);
    final param = createParams({});

    await irisMethodChannel.registerEventHandler(
        ScopedEvent(
            scopedKey: _rtcEngineImplScopedKey,
            registerName: 'RtcEngine_registerAudioSpectrumObserver',
            unregisterName: 'RtcEngine_unregisterAudioSpectrumObserver',
            handler: eventHandlerWrapper),
        jsonEncode(param));
  }

  @override
  void unregisterAudioSpectrumObserver(AudioSpectrumObserver observer) async {
    final eventHandlerWrapper = AudioSpectrumObserverWrapper(observer);
    final param = createParams({});

    await irisMethodChannel.unregisterEventHandler(
        ScopedEvent(
            scopedKey: _rtcEngineImplScopedKey,
            registerName: 'RtcEngine_registerAudioSpectrumObserver',
            unregisterName: 'RtcEngine_unregisterAudioSpectrumObserver',
            handler: eventHandlerWrapper),
        jsonEncode(param));
  }

  @override
  Future<int> getNativeHandle() async {
    final apiType =
        '${isOverrideClassName ? className : 'RtcEngine'}_getNativeHandle';

    final param = createParams({});
    final callApiResult = await irisMethodChannel
        .invokeMethod(IrisMethodCall(apiType, jsonEncode(param)));
    if (callApiResult.irisReturnCode < 0) {
      throw AgoraRtcException(code: callApiResult.irisReturnCode);
    }

    // In 64-bits system, the native handle ptr value (unsigned long 64) can be 2^64 - 1,
    // which may greater than the dart int max value (2^63 - 1), so we can not decode
    // the json with big int native handle ptr value and parse it directly.
    //
    // After dart sdk 2.0 support parse hexadecimal in unsigned int64 range.
    // https://github.com/dart-lang/language/blob/ee1135e0c22391cee17bf3ee262d6a04582d25de/archive/newsletter/20170929.md#semantics
    //
    // So we retrive the native handle ptr value from the json string directly, and
    // parse an int from hexadecimal here.
    final rawJsonStr = callApiResult.rawData;
    // TODO(littlegnal): Replace retrive nativeHandleIntPtr logic after EP-253 landed.
    final rawJsonStrSplit = rawJsonStr.split(',');
    String resultStr = '';
    for (final s in rawJsonStrSplit) {
      if (s.contains('result')) {
        resultStr = s;
      }
    }
    final nativeHandleIntPtr =
        resultStr.substring(resultStr.indexOf(':') + 1, resultStr.length - 1);

    BigInt nativeHandleBI = BigInt.parse(nativeHandleIntPtr);
    int nativeHandleBIHexInt =
        int.parse('0x${nativeHandleBI.toRadixString(16)}');

    return nativeHandleBIHexInt;
  }

  /////////// debug ////////

  /// [type] see [VideoSourceType], only [VideoSourceType.videoSourceCamera], [VideoSourceType.videoSourceRemote] supported
  Future<void> startDumpVideo(int type, String dir) async {
    await irisMethodChannel.invokeMethod(IrisMethodCall(
      'StartDumpVideo',
      jsonEncode({
        'nativeHandle':
            _globalVideoViewController.videoFrameBufferManagerIntPtr,
        'type': type,
        'dir': dir,
      }),
    ));
  }

  Future<void> stopDumpVideo() async {
    await irisMethodChannel.invokeMethod(IrisMethodCall(
      'StopDumpVideo',
      jsonEncode({
        'nativeHandle': _globalVideoViewController.videoFrameBufferManagerIntPtr
      }),
    ));
  }

  //////////////////////////
}

class VideoDeviceManagerImpl extends rtc_engine_binding.VideoDeviceManagerImpl
    with ScopedDisposableObjectMixin
    implements VideoDeviceManager {
  VideoDeviceManagerImpl._(RtcEngine rtcEngine)
      : super(rtcEngine.irisMethodChannel);

  factory VideoDeviceManagerImpl.create(RtcEngine rtcEngine) {
    return rtcEngine.objectPool.putIfAbsent(
        _videoDeviceManagerKey, () => VideoDeviceManagerImpl._(rtcEngine));
  }

  static const _videoDeviceManagerKey = TypedScopedKey(VideoDeviceManagerImpl);

  @override
  Future<List<VideoDeviceInfo>> enumerateVideoDevices() async {
    const apiType = 'VideoDeviceManager_enumerateVideoDevices';
    final param = createParams({});

    final callApiResult = await irisMethodChannel
        .invokeMethod(IrisMethodCall(apiType, jsonEncode(param)));
    if (callApiResult.irisReturnCode < 0) {
      throw AgoraRtcException(code: callApiResult.irisReturnCode);
    }
    final rm = callApiResult.data;
    final result = rm['result'];

    final devicesList = List.from(result);
    final List<VideoDeviceInfo> deviceInfoList = [];
    for (final d in devicesList) {
      final dm = Map<String, dynamic>.from(d);

      deviceInfoList.add(VideoDeviceInfo.fromJson(dm));
    }

    return deviceInfoList;
  }

  @override
  Future<void> release() async {
    markDisposed();
  }

  @override
  Future<void> startDeviceTest(int hwnd) {
    throw AgoraRtcException(code: -ErrorCodeType.errNotSupported.value());
  }

  @override
  Future<void> dispose() {
    return release();
  }
}
