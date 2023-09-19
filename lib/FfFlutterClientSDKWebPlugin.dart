@JS()
library ff_web_plugin;

import 'dart:async';
import 'dart:convert';
import 'dart:js_util';
import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:js/js.dart';
import 'package:logging/logging.dart';
import 'CfClient.dart';
import 'web_plugin_internal//FfJavascriptSDKInterop.dart';

@JS('window')
external dynamic get window;

// Type used to group callback functions used when registering
// stream events with the JavaScript SDK
class JsSDKStreamCallbackFunctions {
  final Function connectedFunction;
  final Function changedFunction;
  final Function stoppedFunction;
  final Function pollingChangedFunction;

  JsSDKStreamCallbackFunctions(
      {required this.connectedFunction,
      required this.stoppedFunction,
      required this.pollingChangedFunction,
      required this.changedFunction});
}

class FfFlutterClientSdkWebPlugin {
  final log = Logger('FfFlutterClientSdkWebPluginLogger');
  // The method calls that the core Flutter SDK can make
  static const _initializeMethodCall = 'initialize';
  static const _registerEventsListenerMethodCall = 'registerEventsListener';
  static const _boolVariationMethodCall = 'boolVariation';
  static const _stringVariationMethodCall = 'stringVariation';
  static const _numberVariationMethodCall = 'numberVariation';
  static const _jsonVariationMethodCall = 'jsonVariation';
  static const _unregisterEventsListenerMethodCall = 'unregisterEventsListener';
  static const _destroyMethodCall = 'destroy';

  // Used to emit JavaScript SDK events to the host MethodChannel
  final StreamController<Map<String, dynamic>> _eventController =
      StreamController.broadcast();

  // Keep track of the JavaScript SDK event subscription so we can close it
  // if users close the SDK.
  StreamSubscription? _eventSubscription;

  // The core Flutter SDK passes uuids over the method channel for each
  // listener that has been registered. This maps the UUID to the event and function callback
  // we pass to the JavaScript SDK, so they can be unregistered by users later.
  Map<String, JsSDKStreamCallbackFunctions> _uuidToEventListenerMap = {};

  // Used to send JavaScript SDK events to the Flutter
  // SDK Code.
  static late MethodChannel _hostChannel;

  static void registerWith(Registrar registrar) {
    final MethodChannel channel = MethodChannel(
      'ff_flutter_client_sdk',
      const StandardMethodCodec(),
      registrar,
    );

    _hostChannel = MethodChannel(
      'cf_flutter_host',
      const StandardMethodCodec(),
      registrar,
    );

    final pluginInstance = FfFlutterClientSdkWebPlugin();
    channel.setMethodCallHandler(pluginInstance._handleMethodCall);
  }

  /// Handles method calls over the [MethodChannel] for this plugin
  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case _initializeMethodCall:
        return await _invokeInitialize(call);
      case _registerEventsListenerMethodCall:
        final uuid = call.arguments['uuid'];
        _registerJsSDKStreamListeners(uuid);
        break;
      case _unregisterEventsListenerMethodCall:
        final uuid = call.arguments['uuid'];
        log.fine("test");
        _unregisterJsSDKStreamListeners(uuid);
        break;
      case _destroyMethodCall:
        destroy();
        break;
      default:
        if (call.method == _boolVariationMethodCall ||
            call.method == _stringVariationMethodCall ||
            call.method == _numberVariationMethodCall ||
            call.method == _jsonVariationMethodCall) {
          return await _invokeVariation(call);
        }
        break;
    }
  }

  Future<bool> _invokeInitialize(MethodCall call) async {
    final String apiKey = call.arguments['apiKey'];
    final Object target = _mapToJsObject(call.arguments['target']);
    final Map flutterOptions = call.arguments['configuration'];

    final javascriptSdkOptions = Options(
        baseUrl: flutterOptions['configUrl'],
        eventUrl: flutterOptions['eventUrl'],
        pollingInterval: flutterOptions['pollingInterval'],
        // Enable polling by default for the JS SDK, so we can fallback to polling
        // of stream fails.
        pollingEnabled: true,
        streamEnabled: flutterOptions['streamEnabled'],
        debug: flutterOptions['debugEnabled']);

    final response =
        JavaScriptSDK.initialize(apiKey, target, javascriptSdkOptions);

    // The JavaScript SDK returns the client instance, whether or not
    // the initialization was successful. We set a reference to it on
    // the global window, and then we can listen if initialization was
    // successful or not.
    setProperty(window, JavaScriptSDKClient.windowReference, response);

    // Used to return the result of initialize after the JavaScript SDK
    // emits either a READY or ERROR event.
    return await _waitForInitializationResult();
  }

  Future<bool> _waitForInitializationResult() async {
    final initializationResult = Completer<bool>();

    // Callback for the JavaScript SDK's READY event. It returns a list of
    // evaluations, but we don't need them in this plugin.
    final readyCallback = ([_]) {
      // While we shouldn't attempt to complete this completer more than once,
      // this is a defensive check and log if it is attempted.
      if (!initializationResult.isCompleted) {
        initializationResult.complete(true);
      } else {
        log.fine(
            'JavaScript SDK success response already handled. Ignoring subsequent response.');
      }
    };

    // Callback to handle errors that can occur when initializing.
    final initErrorCallback = (dynamic error) {
      // Same as above, defensive check.
      if (!initializationResult.isCompleted) {
        log.severe("FF SDK failed to initialize: " +
            (error?.toString() ?? 'Auth error was empty'));
        initializationResult.complete(false);
      } else {
        log.fine(
            'JavaScript SDK failed response already handled. Ignoring subsequent response.');
      }
    };

    // Listen for the JavaScript SDK READY / ERROR_AUTH events to be emitted
    JavaScriptSDKClient.on(Event.READY, allowInterop(readyCallback));
    JavaScriptSDKClient.on(Event.ERROR_AUTH, allowInterop(initErrorCallback));

    final result = await initializationResult.future;

    // After READY or ERROR_AUTH has been emitted and we have a result,
    // then unregister these listeners from the JavaScript SDK as we don't
    // need them anymore.
    JavaScriptSDKClient.off(Event.READY, allowInterop(readyCallback));
    JavaScriptSDKClient.off(Event.ERROR_AUTH, allowInterop(initErrorCallback));

    return result;
  }

  /// Registers the underlying JavaScript SDK event listeners, and emits events
  /// back to the core Flutter SDK using the plugin's host MethodChannel
  void _registerJsSDKStreamListeners(String uuid) {
    final callbacks = {
      // The JavaScript SDK's `CONNECTED` event is emitted when an SSE connection
      // has been lost and reestablished
      Event.CONNECTED: (_) =>
          _eventController.add({'event': EventType.SSE_RESUME}),
      Event.STOPPED: (_) => _eventController.add({'event': EventType.SSE_END}),
      Event.CHANGED: (changeInfo) {
        FlagChange flagChange = changeInfo;
        Map<String, dynamic> evaluationResponse = {
          "flag": flagChange.flag,
          "kind": flagChange.kind,
          "value": flagChange.value
        };
        _eventController.add(
            {'event': EventType.EVALUATION_CHANGE, 'data': evaluationResponse});
      },
      Event.POLLING_CHANGED: (polledFlags) {
        dynamic flags = polledFlags;
        List<dynamic> evaluationResponses = flags.map((flagChange) {
          return {
            "flag": flagChange.flag,
            "kind": flagChange.kind,
            "value": flagChange.value
          };
        }).toList();
        _eventController.add({
          'event': EventType.EVALUATION_POLLING,
          'data': evaluationResponses
        });
      },
    };

    for (final event in callbacks.keys) {
      final callback = callbacks[event];
      JavaScriptSDKClient.on(event, allowInterop(callback!));
    }

    _uuidToEventListenerMap[uuid] = JsSDKStreamCallbackFunctions(
        connectedFunction: callbacks[Event.CONNECTED]!,
        stoppedFunction: callbacks[Event.STOPPED]!,
        changedFunction: callbacks[Event.CHANGED]!,
        pollingChangedFunction: callbacks[Event.POLLING_CHANGED]!);

    _eventSubscription = _eventController.stream.listen((event) {
      switch (event['event']) {
        case EventType.SSE_START:
          log.fine('Internal event received: SSE_START');
          _hostChannel.invokeMethod('start');
          break;
        case EventType.SSE_END:
          log.fine('Internal event received: SSE_END');
          _hostChannel.invokeMethod('end');
          break;
        case EventType.SSE_RESUME:
          log.fine('Internal event received: SSE_RESUME');
          _hostChannel.invokeMethod('resume');
          break;
        case EventType.EVALUATION_POLLING:
          log.fine('Internal event received EVALUATION_POLLING');
          final pollingEvaluations = event['data'];
          _hostChannel.invokeMethod(
              'evaluation_polling', {'evaluationData': pollingEvaluations});
          break;
        case EventType.EVALUATION_CHANGE:
          log.fine('Internal event received EVALUATION_CHANGE');
          final evaluationResponse = event['data'];
          _hostChannel.invokeMethod('evaluation_change', evaluationResponse);
          break;
      }
    });
  }

  void _unregisterJsSDKStreamListeners(String uuid) {
    JsSDKStreamCallbackFunctions? callBackFunctions =
        _uuidToEventListenerMap[uuid];
    if (callBackFunctions != null) {
      JavaScriptSDKClient.off(
          Event.CONNECTED, allowInterop(callBackFunctions.connectedFunction));
      JavaScriptSDKClient.off(
          Event.STOPPED, allowInterop(callBackFunctions.stoppedFunction));
      JavaScriptSDKClient.off(
          Event.CHANGED, allowInterop(callBackFunctions.changedFunction));

      _uuidToEventListenerMap.remove(uuid);
    } else {
      log.warning("Attempted to unregister event listener, but the"
          "requested event listener was not found.");
    }
  }

  Future<dynamic> _invokeVariation(MethodCall call) async {
    final flagIdentifier = call.arguments['flag'];
    final defaultValue = call.arguments['defaultValue'];
    final VariationResult result =
        await JavaScriptSDKClient.variation(flagIdentifier, defaultValue, true);
    if (result.isDefaultValue) {
      log.warning(
          "Flag '${flagIdentifier}' not found when calling ${call.method}. Default value returned.");
    }
    // The JavaScript SDK returns a json string, so we need to encode it as the
    // type expected by the core Flutter SDK
    if (call.method == _jsonVariationMethodCall && !result.isDefaultValue) {
      return jsonDecode(result.value);
    }
    return result.value;
  }

  void destroy() {
    // Cleanup JavaScript SDK resources
    JavaScriptSDKClient.close();

    // Cancel any JS SDK subscriptions that may have been registered
    _eventSubscription?.cancel();
    _uuidToEventListenerMap.clear();
  }

  /// Helper function to turn a map into an object, which is the required
  /// type for interop with JavaScript objects
  Object _mapToJsObject(Map map) {
    final object = newObject();
    map.forEach((k, v) {
      if (v is Map) {
        setProperty(object, k, _mapToJsObject(v));
      } else {
        setProperty(object, k, v);
      }
    });
    return object;
  }
}